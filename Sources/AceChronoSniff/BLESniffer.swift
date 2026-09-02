@preconcurrency import CoreBluetooth
import Foundation

/// 接続対象の指定方法。
enum PeripheralMatcher: Sendable {
    case name(String)
    case identifier(String)

    func matches(peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        switch self {
        case .name(let substring):
            let needle = substring.lowercased()
            let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let candidates = [peripheral.name, localName].compactMap { $0?.lowercased() }
            return candidates.contains { $0.contains(needle) }
        case .identifier(let uuid):
            return peripheral.identifier.uuidString.caseInsensitiveCompare(uuid) == .orderedSame
        }
    }
}

/// 送信したい初期化コマンド。
struct PendingWrite: Sendable {
    let characteristicUUID: String  // 正規化済み 128bit 文字列
    let payload: Data
    let rawUUIDText: String
}

/// 動作モード。
enum SniffMode: Sendable {
    case scan(seconds: Double)
    case dump(matcher: PeripheralMatcher, writes: [PendingWrite])
}

/// CoreBluetooth のデリゲートは専用の DispatchQueue 上で動く。
/// 内部状態の読み書きはすべてこのキュー上でのみ行うため `@unchecked Sendable`。
final class BLESniffer: NSObject, @unchecked Sendable {
    private let mode: SniffMode
    private let serviceFilter: [CBUUID]?
    private let logger: LogWriter
    private let queue = DispatchQueue(label: "com.acechrono.sniff.ble")

    private var central: CBCentralManager!
    private var seenPeripherals = [UUID: Date]()
    /// 接続対象を強参照で保持しないと CoreBluetooth が解放してしまう。
    private var target: CBPeripheral?
    private var pendingServiceCount = 0
    private var pendingReads = Set<String>()
    private var lastPacketAt: Date?
    private var didStartSession = false

    init(mode: SniffMode, serviceFilter: [CBUUID]?, logger: LogWriter) {
        self.mode = mode
        self.serviceFilter = serviceFilter
        self.logger = logger
        super.init()
    }

    func start() {
        installAbortHint()
        central = CBCentralManager(delegate: self, queue: queue)
        installSignalHandler()
    }

    /// Bluetooth の TCC 権限が無い場合、CoreBluetooth は
    /// `CBCentralManager` の生成時に何も出力せず SIGABRT でプロセスを落とす。
    /// 原因が分かるようにヒントを出してから既定の動作に戻す。
    private func installAbortHint() {
        signal(SIGABRT) { _ in
            let hint = """

                acechrono-sniff: Bluetooth へのアクセスが OS に拒否されました (TCC)。
                  - Terminal.app / iTerm.app から直接実行してください。
                    エディタや他のアプリから起動すると、そのアプリ側に Bluetooth 権限が必要になります。
                  - システム設定 > プライバシーとセキュリティ > Bluetooth で
                    実行元のアプリを ON にし、そのアプリを再起動してください。

                """
            hint.withCString { pointer in
                _ = write(STDERR_FILENO, pointer, strlen(pointer))
            }
            signal(SIGABRT, SIG_DFL)
            raise(SIGABRT)
        }
    }

    // MARK: - 出力ヘルパ

    private func out(_ line: String) {
        logger.log(line)
    }

    private func installSignalHandler() {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { exit(0) }
            self.out("")
            self.out("[stopped by SIGINT]")
            if let path = self.logger.path {
                print("log: \(path)")
            }
            self.logger.close()
            exit(0)
        }
        source.resume()
        signalSource = source
    }

    private var signalSource: DispatchSourceSignal?

    // MARK: - 状態

    private func handle(state: CBManagerState) {
        switch state {
        case .poweredOn:
            beginWork()
        case .poweredOff:
            fail("""
                Bluetooth はオフです。メニューバーまたはシステム設定から Bluetooth をオンにしてください。
                """)
        case .unauthorized:
            fail("""
                Bluetooth の使用が許可されていません。
                システム設定 > プライバシーとセキュリティ > Bluetooth を開き、
                このコマンドを実行しているアプリ（Terminal.app / iTerm.app など）を有効にしてから
                そのアプリを再起動して、もう一度実行してください。
                """)
        case .unsupported:
            fail("この Mac では Bluetooth Low Energy が利用できません。")
        case .resetting:
            print("Bluetooth スタックがリセット中です。しばらく待ちます…")
        case .unknown:
            print("Bluetooth の状態を確認中…")
        @unknown default:
            print("Bluetooth の状態が不明です (\(state.rawValue))")
        }
    }

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
        logger.close()
        exit(1)
    }

    private func beginWork() {
        guard !didStartSession else { return }
        didStartSession = true

        switch mode {
        case .scan(let seconds):
            print("スキャン開始（\(Int(seconds)) 秒）… Ctrl-C で中断")
            if let serviceFilter {
                print("service filter: \(serviceFilter.map(\.uuidString).joined(separator: ", "))")
            }
            print("")
            central.scanForPeripherals(
                withServices: serviceFilter,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self else { exit(0) }
                self.central.stopScan()
                print("")
                print("スキャン終了: \(self.seenPeripherals.count) 台検出")
                exit(0)
            }

        case .dump(let matcher, _):
            switch matcher {
            case .name(let n): print("\"\(n)\" を含む名前のデバイスを探しています…")
            case .identifier(let id): print("identifier \(id) のデバイスを探しています…")
            }
            central.scanForPeripherals(
                withServices: serviceFilter,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
    }

    // MARK: - スキャン結果の表示

    private func describeAdvertisement(_ data: [String: Any], rssi: NSNumber, peripheral: CBPeripheral) -> String {
        let name = peripheral.name
            ?? (data[CBAdvertisementDataLocalNameKey] as? String)
            ?? "(no name)"
        var parts = [
            "name: \(name)",
            "id: \(peripheral.identifier.uuidString)",
            "rssi: \(rssi)",
        ]
        if let services = data[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], !services.isEmpty {
            parts.append("services: [\(services.map(\.uuidString).joined(separator: ", "))]")
        } else {
            parts.append("services: []")
        }
        if let overflow = data[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID], !overflow.isEmpty {
            parts.append("overflow: [\(overflow.map(\.uuidString).joined(separator: ", "))]")
        }
        if let mfg = data[CBAdvertisementDataManufacturerDataKey] as? Data {
            parts.append("mfg: \(Hex.string(mfg))")
        }
        if let serviceData = data[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data], !serviceData.isEmpty {
            let rendered = serviceData
                .map { "\($0.key.uuidString)=\(Hex.string($0.value))" }
                .joined(separator: ", ")
            parts.append("serviceData: [\(rendered)]")
        }
        if let connectable = data[CBAdvertisementDataIsConnectable] as? NSNumber {
            parts.append("connectable: \(connectable.boolValue)")
        }
        if let txPower = data[CBAdvertisementDataTxPowerLevelKey] as? NSNumber {
            parts.append("tx: \(txPower)")
        }
        return parts.joined(separator: "  ")
    }

    // MARK: - 接続後の処理

    private func startDiscovery(_ peripheral: CBPeripheral) {
        pendingServiceCount = 0
        pendingReads.removeAll()
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    private func finishDiscovery(_ peripheral: CBPeripheral) {
        out("")
        out("=== readable characteristics を 1 回ずつ read します ===")
        var readCount = 0
        for service in peripheral.services ?? [] {
            for characteristic in service.characteristics ?? [] where characteristic.properties.contains(.read) {
                pendingReads.insert(UUIDText.canonical(characteristic.uuid))
                peripheral.readValue(for: characteristic)
                readCount += 1
            }
        }
        if readCount == 0 { out("(read 可能な characteristic はありません)") }

        out("")
        out("=== notify / indicate を全て購読します ===")
        var notifyCount = 0
        for service in peripheral.services ?? [] {
            for characteristic in service.characteristics ?? [] {
                let props = characteristic.properties
                guard props.contains(.notify) || props.contains(.indicate) else { continue }
                peripheral.setNotifyValue(true, for: characteristic)
                out("subscribe: \(characteristic.uuid.uuidString) (service \(service.uuid.uuidString))")
                notifyCount += 1
            }
        }
        if notifyCount == 0 { out("(notify/indicate 可能な characteristic はありません)") }

        out("")
        out("=== 受信待機中。Ctrl-C で終了 ===")
        if let path = logger.path { out("log file: \(path)") }
        out("")

        performWrites(peripheral)
    }

    private func performWrites(_ peripheral: CBPeripheral) {
        guard case .dump(_, let writes) = mode, !writes.isEmpty else { return }
        // 購読が確定してから送るため少し待つ。
        queue.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            for pending in writes {
                guard let characteristic = self.findCharacteristic(pending.characteristicUUID, in: peripheral) else {
                    self.out("write: \(pending.rawUUIDText) が見つかりません（スキップ）")
                    continue
                }
                let props = characteristic.properties
                let type: CBCharacteristicWriteType
                if props.contains(.write) {
                    type = .withResponse
                } else if props.contains(.writeWithoutResponse) {
                    type = .withoutResponse
                } else {
                    self.out("write: \(characteristic.uuid.uuidString) は書き込み不可（スキップ）")
                    continue
                }
                let kind = (type == .withResponse) ? "withResponse" : "withoutResponse"
                self.out("[\(Timestamp.iso8601(Date()))] write -> \(characteristic.uuid.uuidString) (\(kind)) len=\(pending.payload.count) hex: \(Hex.string(pending.payload))")
                peripheral.writeValue(pending.payload, for: characteristic, type: type)
                if type == .withoutResponse {
                    self.out("  -> withoutResponse のため応答はありません（送信済み）")
                }
            }
        }
    }

    private func findCharacteristic(_ canonicalUUID: String, in peripheral: CBPeripheral) -> CBCharacteristic? {
        for service in peripheral.services ?? [] {
            for characteristic in service.characteristics ?? []
            where UUIDText.canonical(characteristic.uuid) == canonicalUUID {
                return characteristic
            }
        }
        return nil
    }

    private func reconnect(_ peripheral: CBPeripheral) {
        out("再接続を試みます…（デバイスの電源が入るまで待機します）")
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.central.connect(peripheral, options: nil)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLESniffer: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        handle(state: central.state)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        switch mode {
        case .scan:
            guard seenPeripherals[peripheral.identifier] == nil else { return }
            seenPeripherals[peripheral.identifier] = Date()
            print(describeAdvertisement(advertisementData, rssi: RSSI, peripheral: peripheral))

        case .dump(let matcher, _):
            guard target == nil else { return }
            guard matcher.matches(peripheral: peripheral, advertisementData: advertisementData) else { return }
            central.stopScan()
            target = peripheral
            out("見つかりました: \(describeAdvertisement(advertisementData, rssi: RSSI, peripheral: peripheral))")
            out("接続中…")
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        out("接続しました: \(peripheral.name ?? "(no name)") [\(peripheral.identifier.uuidString)]")
        out("")
        out("=== GATT ツリー ===")
        startDiscovery(peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        out("接続に失敗しました: \(error?.localizedDescription ?? "unknown error")")
        reconnect(peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        let reason = error.map { " (\($0.localizedDescription))" } ?? ""
        out("[\(Timestamp.iso8601(Date()))] 切断されました\(reason)")
        reconnect(peripheral)
    }
}

// MARK: - CBPeripheralDelegate

extension BLESniffer: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error {
            out("service discovery に失敗: \(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        pendingServiceCount = services.count
        if services.isEmpty {
            out("(service がありません)")
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        out("service \(service.uuid.uuidString)\(service.isPrimary ? " (primary)" : "")")
        if let error {
            out("  characteristic discovery に失敗: \(error.localizedDescription)")
        }
        for characteristic in service.characteristics ?? [] {
            let props = characteristic.properties.descriptions.joined(separator: ",")
            out("  └─ char \(characteristic.uuid.uuidString)  [\(props)]")
        }
        pendingServiceCount -= 1
        if pendingServiceCount <= 0 {
            finishDiscovery(peripheral)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if let error {
            out("value error on \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            return
        }
        let data = characteristic.value ?? Data()
        let key = UUIDText.canonical(characteristic.uuid)
        let now = Date()

        if pendingReads.contains(key) {
            pendingReads.remove(key)
            out("read \(characteristic.uuid.uuidString) len=\(data.count) hex: \(Hex.string(data)) ascii: \(Hex.ascii(data))")
            return
        }

        let delta = lastPacketAt.map { now.timeIntervalSince($0) * 1000 }
        lastPacketAt = now
        let deltaText = delta.map { String(format: "[+%.1f ms]", $0) } ?? "[+---- ms]"
        out("[\(Timestamp.iso8601(now))] \(deltaText) \(characteristic.uuid.uuidString) len=\(data.count) hex: \(Hex.string(data)) ascii: \(Hex.ascii(data))")
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if let error {
            out("write 失敗 \(characteristic.uuid.uuidString): \(error.localizedDescription)")
        } else {
            out("write 成功 \(characteristic.uuid.uuidString)")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if let error {
            out("notify 設定失敗 \(characteristic.uuid.uuidString): \(error.localizedDescription)")
        }
    }

    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        out("デバイス名が変わりました: \(peripheral.name ?? "(no name)")")
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        out("service が変更されました。再探索します。")
        startDiscovery(peripheral)
    }
}
