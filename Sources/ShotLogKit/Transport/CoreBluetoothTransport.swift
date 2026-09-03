#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
import Foundation

/// CoreBluetooth による実機トランスポート（iOS / macOS 共通）。
///
/// `Sources/ShotLogSniff/BLESniffer.swift` の実績あるコードを、`ChronoTransport` の
/// 形に合わせて移植したもの。
///
/// 並行性の設計:
/// * CoreBluetooth のデリゲートは**専用の直列キュー**上で呼ばれる。内部状態はすべて
///   このキュー上でしか触らないので `@unchecked Sendable` にしてある。
/// * 非同期 API はキューへ hop してから状態を触り、結果は `AsyncStream<TransportEvent>` で返す。
/// * `CBCentralManager` は**最初にスキャン / 接続を要求した時点で生成する**。
///   生成した瞬間に OS の Bluetooth 許可ダイアログが出るため、リプレイモードでは
///   一度も作られないようにしている。
///
/// 安全策:
/// * 書き込み先は `ChronoUUIDs.forbiddenWriteCharacteristics` でホワイトリスト外を拒否する。
///   OTA 制御 characteristic へ書くと本体が OTA ブートローダへ落ちる（`docs/PROTOCOL.md` §11）。
/// * `.connected` は **service / characteristic の探索が終わってから**流す。
///   これにより `ChronoDevice` は `.connected` 直後に `subscribe` / `write` してよい。
public final class CoreBluetoothTransport: NSObject, ChronoTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.yhakamay.shotlog.kit.ble")

    /// 探索するサービス。`nil` で全件探索。既定は notify / write の 2 つだけ
    /// （OTA サービスは**列挙もしない**ので、間違って書き込みようがない）。
    private let servicesToDiscover: [CBUUID]?

    public nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation

    // MARK: 以下すべて `queue` 上でのみ触る

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
            // AC6000 はサービスをアドバタイズしないので、既定では services: nil で拾って
            // 名前 / manufacturer data で絞る（`docs/PROTOCOL.md` §1.1）。
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
                // 電源が入るのを待ってから繋ぐ（`centralManagerDidUpdateState` で再開）。
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
            // 🚫 OTA 制御への書き込みは何があっても通さない（文鎮化の防止）。
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

    // MARK: - キューへの hop

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

    // MARK: - 内部（すべて `queue` 上）

    private func ensureCentral() {
        guard central == nil, !isShutDown else { return }
        central = CBCentralManager(delegate: self, queue: queue)
    }

    private func startScanIfPossible() {
        guard wantsScan, let central, central.state == .poweredOn else { return }
        // **重複した広告も受け取る。** 同じ機器の広告を 1 本しか受け取らないと
        // RSSI が最初の 1 回で固まり、「近づけたら強くなる」という一覧の使いかた
        // （複数台から手元の 1 台を選ぶ）が成立しない。
        // スキャンは接続が成立した時点で止まるので、鳴りっぱなしにはならない。
        central.scanForPeripherals(
            withServices: scanServices,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    /// 広告がこのスキャンの対象か。
    ///
    /// 名前フィルタが指定されていれば「名前の部分一致」**または**
    /// 「manufacturer data が `00 05 08` で始まる」で拾う。名前が広告に載らない
    /// 個体・タイミングがあり得るため、どちらか一方で通す。
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
            // 電源待ちで保留していた接続を再開する。
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
        // `.connected` は探索完了後に流す（`ChronoDevice` が直後に subscribe できるように）。
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
        // 本体のファームが GATT を作り直した。探索からやり直す。
        characteristics.removeAll()
        peripheral.discoverServices(servicesToDiscover)
    }
}
#endif
