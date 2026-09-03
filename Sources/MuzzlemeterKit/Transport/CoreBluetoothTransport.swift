#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
import Foundation

/// The real-hardware transport backed by CoreBluetooth (shared by iOS / macOS).
///
/// The proven code from `Sources/MuzzlemeterSniff/BLESniffer.swift`, ported into the
/// shape of `ChronoTransport`.

/// Concurrency design:
/// * CoreBluetooth delegate callbacks run on a **dedicated serial queue**. All internal
///   state is only ever touched on that queue, hence `@unchecked Sendable`.
/// * Async APIs hop onto the queue before touching state, and results come back through
///   `AsyncStream<TransportEvent>`.
/// * `CBCentralManager` is **created only when a scan / connection is first requested**.
///   Creating it is what triggers the OS's Bluetooth permission dialog, so replay mode
///   is built to never create one at all.
///
/// Safety measures:
/// * Write targets outside `ChronoUUIDs.forbiddenWriteCharacteristics`' allowlist are
///   rejected. Writing to the OTA control characteristic drops the device into the OTA
///   bootloader (`docs/PROTOCOL.md` §11).
/// * `.connected` is delivered **only after service / characteristic discovery
///   finishes**. That lets `ChronoDevice` call `subscribe` / `write` right after
///   `.connected`.
public final class CoreBluetoothTransport: NSObject, ChronoTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.yhakamay.muzzlemeter.kit.ble")

    /// The services to discover. `nil` discovers everything. Defaults to just the notify
    /// and write services (the OTA service isn't even **enumerated**, so there's no way
    /// to accidentally write to it).
    private let servicesToDiscover: [CBUUID]?

    public nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation

    // MARK: everything below is only ever touched on `queue`

    private var central: CBCentralManager?
    private var wantsScan = false
    private var scanNameFilter: String?
    private var scanServices: [CBUUID]?
    private var discoveredPeripherals = [UUID: CBPeripheral]()
    private var target: CBPeripheral?
    private var pendingConnect: UUID?
    private var pendingServiceCount = 0
    private var characteristics = [UUID: CBCharacteristic]()
    private var isShutDown = false

    public init(servicesToDiscover: [UUID]? = [ChronoUUIDs.notifyService, ChronoUUIDs.writeService]) {
        self.servicesToDiscover = servicesToDiscover?.map { CBUUID(nsuuid: $0) }
        let (stream, continuation) = AsyncStream<TransportEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = continuation
        super.init()
    }

    // MARK: - ChronoTransport

    public func scan(services: [UUID]?, nameFilter: String?) async throws {
        await onQueue {
            self.wantsScan = true
            self.scanNameFilter = nameFilter
            // The AC6000 doesn't advertise a service, so by default this scans with
            // services: nil and filters by name / manufacturer data instead
            // (`docs/PROTOCOL.md` §1.1).
            self.scanServices = services?.map { CBUUID(nsuuid: $0) }
            self.ensureCentral()
            self.startScanIfPossible()
        }
    }

    public func stopScan() async {
        await onQueue {
            self.wantsScan = false
            self.central?.stopScan()
        }
    }

    public func connect(to peripheral: UUID) async throws {
        try await onQueueThrowing {
            self.ensureCentral()
            guard let central = self.central else {
                throw ChronoTransportError.unavailable("CBCentralManager を生成できません")
            }
            let found = self.discoveredPeripherals[peripheral]
                ?? central.retrievePeripherals(withIdentifiers: [peripheral]).first
            guard let found else {
                throw ChronoTransportError.unavailable("未知の peripheral: \(peripheral)")
            }
            self.discoveredPeripherals[peripheral] = found
            self.target = found
            self.pendingConnect = peripheral
            self.characteristics.removeAll()
            found.delegate = self
            guard central.state == .poweredOn else {
                // Wait for power-on before connecting (resumed in
                // `centralManagerDidUpdateState`).
                return
            }
            central.connect(found, options: nil)
        }
    }

    public func disconnect() async {
        await onQueue {
            guard let central = self.central, let target = self.target else { return }
            central.cancelPeripheralConnection(target)
        }
    }

    public func subscribe(to characteristic: UUID) async throws {
        try await onQueueThrowing {
            guard let peripheral = self.target, peripheral.state == .connected else {
                throw ChronoTransportError.notConnected
            }
            guard let found = self.characteristics[characteristic] else {
                throw ChronoTransportError.unknownCharacteristic(characteristic)
            }
            let props = found.properties
            guard props.contains(.notify) || props.contains(.indicate) else {
                throw ChronoTransportError.unknownCharacteristic(characteristic)
            }
            peripheral.setNotifyValue(true, for: found)
        }
    }

    public func write(_ data: Data, to characteristic: UUID, withResponse: Bool) async throws {
        try await onQueueThrowing {
            // A write to the OTA control point is never allowed through, no matter what
            // (prevents bricking).
            guard !ChronoUUIDs.isForbiddenWriteTarget(characteristic) else {
                assertionFailure("OTA characteristic への書き込みが試みられました: \(characteristic)")
                throw ChronoTransportError.forbiddenCharacteristic(characteristic)
            }
            guard let peripheral = self.target, peripheral.state == .connected else {
                throw ChronoTransportError.notConnected
            }
            guard let found = self.characteristics[characteristic] else {
                throw ChronoTransportError.unknownCharacteristic(characteristic)
            }
            let props = found.properties
            let type: CBCharacteristicWriteType
            if withResponse, props.contains(.write) {
                type = .withResponse
            } else if !withResponse, props.contains(.writeWithoutResponse) {
                type = .withoutResponse
            } else if props.contains(.write) {
                type = .withResponse
            } else if props.contains(.writeWithoutResponse) {
                type = .withoutResponse
            } else {
                throw ChronoTransportError.writeNotSupported(characteristic)
            }
            peripheral.writeValue(data, for: found, type: type)
        }
    }

    public func finishSetup() async {}

    public func shutdown() async {
        await onQueue {
            guard !self.isShutDown else { return }
            self.isShutDown = true
            self.central?.stopScan()
            if let target = self.target {
                self.central?.cancelPeripheralConnection(target)
            }
            self.target = nil
            self.characteristics.removeAll()
            self.continuation.finish()
        }
    }

    // MARK: - Hopping onto the queue

    private func onQueue(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                body()
                continuation.resume()
            }
        }
    }

    private func onQueueThrowing(_ body: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try body()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Internals (all on `queue`)

    private func ensureCentral() {
        guard central == nil, !isShutDown else { return }
        central = CBCentralManager(delegate: self, queue: queue)
    }

    private func startScanIfPossible() {
        guard wantsScan, let central, central.state == .poweredOn else { return }
        // **Also receive duplicate advertisements.** If only the first advertisement
        // from a device were received, RSSI would freeze at that first reading, and the
        // list's whole point — picking out the one device in hand from several — would
        // break. Scanning stops once a connection is established, so this doesn't run
        // forever.
        central.scanForPeripherals(
            withServices: scanServices,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    /// Whether an advertisement matches this scan.
    ///
    /// If a name filter is given, this matches on "partial name match" **or**
    /// "manufacturer data starts with `00 05 08`." There can be units or moments where
    /// the name isn't in the advertisement, so either condition is accepted.
    private func matches(name: String?, manufacturerData: Data?) -> Bool {
        guard let filter = scanNameFilter, !filter.isEmpty else { return true }
        if let name, name.lowercased().contains(filter.lowercased()) { return true }
        return ChronoUUIDs.matchesManufacturerData(manufacturerData)
    }

    private func normalized(_ uuid: CBUUID) -> UUID {
        BluetoothUUID.parse(uuid.uuidString) ?? UUID()
    }
}

// MARK: - CBCentralManagerDelegate

extension CoreBluetoothTransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanIfPossible()
            // Resume a connection that was on hold waiting for power-on.
            if let pending = pendingConnect, let peripheral = discoveredPeripherals[pending],
               peripheral.state != .connected {
                central.connect(peripheral, options: nil)
            }
        case .poweredOff:
            continuation.yield(.failed(reason: "Bluetooth がオフです"))
        case .unauthorized:
            continuation.yield(.failed(reason: "Bluetooth の使用が許可されていません"))
        case .unsupported:
            continuation.yield(.failed(reason: "この端末では Bluetooth Low Energy が使えません"))
        case .resetting, .unknown:
            break
        @unknown default:
            break
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? localName
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        guard matches(name: name, manufacturerData: manufacturerData) else { return }

        discoveredPeripherals[peripheral.identifier] = peripheral
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .map(normalized)
        continuation.yield(
            .discovered(
                DiscoveredPeripheral(
                    id: peripheral.identifier,
                    name: name,
                    rssi: RSSI.intValue,
                    advertisedServices: services,
                    manufacturerData: manufacturerData
                )
            )
        )
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        pendingConnect = nil
        target = peripheral
        characteristics.removeAll()
        pendingServiceCount = 0
        peripheral.delegate = self
        // `.connected` is delivered only after discovery finishes (so `ChronoDevice` can
        // subscribe right away).
        peripheral.discoverServices(servicesToDiscover)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        pendingConnect = nil
        continuation.yield(
            .failed(reason: "接続に失敗しました: \(error?.localizedDescription ?? "不明なエラー")")
        )
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        characteristics.removeAll()
        if target?.identifier == peripheral.identifier { target = nil }
        continuation.yield(
            .disconnected(peripheral: peripheral.identifier, reason: error?.localizedDescription)
        )
    }
}

// MARK: - CBPeripheralDelegate

extension CoreBluetoothTransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error {
            continuation.yield(.failed(reason: "サービス探索に失敗: \(error.localizedDescription)"))
            return
        }
        let services = peripheral.services ?? []
        pendingServiceCount = services.count
        guard !services.isEmpty else {
            continuation.yield(.failed(reason: "必要なサービスが見つかりません"))
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        for characteristic in service.characteristics ?? [] {
            characteristics[normalized(characteristic.uuid)] = characteristic
        }
        pendingServiceCount -= 1
        guard pendingServiceCount <= 0 else { return }
        continuation.yield(.connected(peripheral: peripheral.identifier))
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if let error {
            continuation.yield(.failed(reason: "値の受信に失敗: \(error.localizedDescription)"))
            return
        }
        guard let data = characteristic.value else { return }
        continuation.yield(.value(characteristic: normalized(characteristic.uuid), data: data))
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if let error {
            continuation.yield(.failed(reason: "購読に失敗: \(error.localizedDescription)"))
            return
        }
        guard characteristic.isNotifying else { return }
        continuation.yield(.subscribed(characteristic: normalized(characteristic.uuid)))
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard let error else { return }
        continuation.yield(.failed(reason: "書き込みに失敗: \(error.localizedDescription)"))
    }

    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        // The device's firmware rebuilt its GATT table. Start discovery over.
        characteristics.removeAll()
        peripheral.discoverServices(servicesToDiscover)
    }
}
#endif
