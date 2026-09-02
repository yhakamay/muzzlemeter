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
    /// - Parameters:
    ///   - writeDelay: `--write` を連続で送るときの間隔（秒）。応答をどの write に対する
    ///     ものか対応付けられるように、既定でも 0 にはしない。
    ///   - interactive: 購読・初期 write 完了後に stdin から追加コマンドを受け付けるか。
    case dump(
        matcher: PeripheralMatcher,
        writes: [PendingWrite],
        writeDelay: Double,
        interactive: Bool
    )
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

    // MARK: 対話モードの状態（すべて `queue` 上でのみ触る）

    /// stdin リーダースレッドを起動済みか（再接続で二重に起動しないため）。
    private var interactiveStarted = false
    /// プロンプト "> " が画面に出たまま改行されていない。
    private var promptShown = false
    /// write / read の結果を待っていて、返ってきたらプロンプトを出す。
    private var promptPending = false
    /// 応答が返らなかったときの保険タイマーを、最新の要求だけに効かせるための世代番号。
    private var promptToken = 0
    /// `q` / EOF による終了処理中。再接続を抑止する。
    private var isQuitting = false

    /// `--write-delay`（秒）。dump 以外では使わない。
    private var writeDelay: Double {
        if case .dump(_, _, let delay, _) = mode { return delay }
        return 0
    }

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
        // プロンプトを出したまま notify が飛んでくると "> [2026-..." と繋がってしまうので、
        // 先に改行だけ入れる（プロンプトはログファイルには書かない）。
        if promptShown {
            print("")
            promptShown = false
        }
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

        case .dump(let matcher, _, _, _):
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

    /// `--write` を `writeDelay` 間隔で 1 件ずつ送り、終わったら対話モードへ入る。
    private func performWrites(_ peripheral: CBPeripheral) {
        guard case .dump(_, let writes, let delay, _) = mode else { return }
        // 購読が確定してから送るため少し待つ。
        queue.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.runWrite(at: 0, of: writes, delay: delay, on: peripheral)
        }
    }

    private func runWrite(
        at index: Int,
        of writes: [PendingWrite],
        delay: Double,
        on peripheral: CBPeripheral
    ) {
        guard index < writes.count else {
            startInteractiveIfNeeded(peripheral)
            return
        }
        let pending = writes[index]
        if let characteristic = findCharacteristic(pending.characteristicUUID, in: peripheral) {
            _ = send(pending.payload, to: characteristic, on: peripheral)
        } else {
            out("write: \(pending.rawUUIDText) が見つかりません（スキップ）")
        }
        // 応答をどの write のものか対応付けられるよう、次の送信まで間隔を空ける。
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runWrite(at: index + 1, of: writes, delay: delay, on: peripheral)
        }
    }

    /// 1 件送信して、応答を待つ必要がある（withResponse）かどうかを返す。
    private func send(
        _ payload: Data,
        to characteristic: CBCharacteristic,
        on peripheral: CBPeripheral
    ) -> Bool {
        let props = characteristic.properties
        let type: CBCharacteristicWriteType
        if props.contains(.write) {
            type = .withResponse
        } else if props.contains(.writeWithoutResponse) {
            type = .withoutResponse
        } else {
            out("write: \(characteristic.uuid.uuidString) は書き込み不可（スキップ）")
            return false
        }
        let kind = (type == .withResponse) ? "withResponse" : "withoutResponse"
        out(
            "[\(Timestamp.iso8601(Date()))] write -> \(characteristic.uuid.uuidString) (\(kind)) len=\(payload.count) hex: \(Hex.string(payload))"
        )
        peripheral.writeValue(payload, for: characteristic, type: type)
        if type == .withoutResponse {
            out("  -> withoutResponse のため応答はありません（送信済み）")
            return false
        }
        return true
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

    /// 完全一致（16bit / 32bit の短縮形も正規化して比較）を先に試し、
    /// 見つからなければ UUID 文字列の前置一致で探す。曖昧なら候補を出して nil を返す。
    private func resolveCharacteristic(_ text: String, in peripheral: CBPeripheral) -> CBCharacteristic? {
        let all = (peripheral.services ?? []).flatMap { $0.characteristics ?? [] }
        if UUIDText.makeCBUUID(text) != nil {
            let canonical = UUIDText.canonical(text)
            if let exact = all.first(where: { UUIDText.canonical($0.uuid) == canonical }) {
                return exact
            }
        }
        let needle = text.uppercased()
        let matches = all.filter {
            $0.uuid.uuidString.uppercased().hasPrefix(needle)
                || UUIDText.canonical($0.uuid).hasPrefix(needle)
        }
        switch matches.count {
        case 1:
            return matches[0]
        case 0:
            out("characteristic が見つかりません: \(text)")
            return nil
        default:
            let candidates = matches.map(\.uuid.uuidString).joined(separator: ", ")
            out("characteristic が一意に決まりません: \(text) -> [\(candidates)]")
            return nil
        }
    }

    /// 既定の write 先。write（応答あり）を持つものを優先し、無ければ
    /// writeWithoutResponse を持つ最初のものを使う。
    private func defaultWriteCharacteristic(in peripheral: CBPeripheral) -> CBCharacteristic? {
        let all = (peripheral.services ?? []).flatMap { $0.characteristics ?? [] }
        if let withResponse = all.first(where: { $0.properties.contains(.write) }) {
            return withResponse
        }
        return all.first { $0.properties.contains(.writeWithoutResponse) }
    }

    private func printGATTTree(_ peripheral: CBPeripheral) {
        out("=== GATT ツリー ===")
        let services = peripheral.services ?? []
        if services.isEmpty {
            out("(service がありません)")
            return
        }
        for service in services {
            out("service \(service.uuid.uuidString)\(service.isPrimary ? " (primary)" : "")")
            for characteristic in service.characteristics ?? [] {
                let props = characteristic.properties.descriptions.joined(separator: ",")
                let notifying = characteristic.isNotifying ? " *notifying*" : ""
                out("  └─ char \(characteristic.uuid.uuidString)  [\(props)]\(notifying)")
            }
        }
    }

    private func reconnect(_ peripheral: CBPeripheral) {
        guard !isQuitting else { return }
        out("再接続を試みます…（デバイスの電源が入るまで待機します）")
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.isQuitting else { return }
            self.central.connect(peripheral, options: nil)
        }
    }
}

// MARK: - 対話モード

extension BLESniffer {
    /// 購読と `--write` が済んだ後に呼ばれる。stdin リーダーは 1 回だけ起動する。
    private func startInteractiveIfNeeded(_ peripheral: CBPeripheral) {
        guard case .dump(_, _, _, let interactive) = mode, interactive else { return }
        guard !interactiveStarted else {
            // 再接続後。既定の write 先を出し直してプロンプトに戻る。
            announceDefaultWriteCharacteristic(peripheral)
            prompt()
            return
        }
        interactiveStarted = true
        out("")
        out(InteractiveCommand.helpText)
        announceDefaultWriteCharacteristic(peripheral)
        out("")
        prompt()
        startStdinReader()
    }

    private func announceDefaultWriteCharacteristic(_ peripheral: CBPeripheral) {
        if let characteristic = defaultWriteCharacteristic(in: peripheral) {
            out("既定の write 先: \(characteristic.uuid.uuidString) [\(characteristic.properties.descriptions.joined(separator: ","))]")
        } else {
            out("既定の write 先: (書き込める characteristic がありません)")
        }
    }

    /// `readLine()` はブロックするので専用スレッドで回し、BLE 操作は CoreBluetooth の
    /// キューへ hop させる。内部状態を触るのは常に `queue` 上だけになる。
    private func startStdinReader() {
        // 端末なら人間が打つ速度で十分だが、パイプやリダイレクトだと全行が一瞬で
        // 流れ込んで write が連続してしまう。--write と同じ間隔で読むペースを落とす。
        let pacing = (isatty(STDIN_FILENO) != 0) ? 0 : writeDelay
        let thread = Thread { [weak self] in
            var isFirst = true
            while let line = readLine(strippingNewline: true) {
                guard let self else { return }
                if !isFirst, pacing > 0 { Thread.sleep(forTimeInterval: pacing) }
                isFirst = false
                self.queue.async { self.handle(line: line) }
            }
            guard let self else { return }
            // 最後のコマンドの応答が出てから終わるよう、少し待ってから終了する。
            Thread.sleep(forTimeInterval: max(pacing, 0.2))
            self.queue.async { self.quit(reason: "EOF") }
        }
        thread.name = "acechrono-sniff.stdin"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    private func handle(line: String) {
        // ユーザーが Enter を押した時点で端末側が改行しているので、プロンプトは消えている。
        promptShown = false

        switch InteractiveCommand.parse(line) {
        case .none:
            prompt()

        case .help:
            out(InteractiveCommand.helpText)
            prompt()

        case .quit:
            quit(reason: "q")

        case .list:
            guard let peripheral = target else {
                out("未接続です。")
                prompt()
                return
            }
            printGATTTree(peripheral)
            prompt()

        case .write(let targetText, let payload):
            guard let peripheral = target else {
                out("未接続です。")
                prompt()
                return
            }
            let characteristic: CBCharacteristic?
            if let targetText {
                characteristic = resolveCharacteristic(targetText, in: peripheral)
            } else {
                characteristic = defaultWriteCharacteristic(in: peripheral)
                if characteristic == nil { out("書き込める characteristic がありません。") }
            }
            guard let characteristic else {
                prompt()
                return
            }
            if send(payload, to: characteristic, on: peripheral) {
                deferPrompt()  // didWriteValueFor を待つ
            } else {
                prompt()
            }

        case .read(let targetText):
            guard let peripheral = target,
                let characteristic = resolveCharacteristic(targetText, in: peripheral)
            else {
                if target == nil { out("未接続です。") }
                prompt()
                return
            }
            guard characteristic.properties.contains(.read) else {
                out("read 不可: \(characteristic.uuid.uuidString)")
                prompt()
                return
            }
            pendingReads.insert(UUIDText.canonical(characteristic.uuid))
            peripheral.readValue(for: characteristic)
            deferPrompt()  // didUpdateValueFor を待つ

        case .setNotify(let targetText, let enabled):
            guard let peripheral = target,
                let characteristic = resolveCharacteristic(targetText, in: peripheral)
            else {
                if target == nil { out("未接続です。") }
                prompt()
                return
            }
            let props = characteristic.properties
            guard props.contains(.notify) || props.contains(.indicate) else {
                out("notify/indicate 不可: \(characteristic.uuid.uuidString)")
                prompt()
                return
            }
            out("\(enabled ? "subscribe" : "unsubscribe"): \(characteristic.uuid.uuidString)")
            peripheral.setNotifyValue(enabled, for: characteristic)
            deferPrompt()  // didUpdateNotificationStateFor を待つ

        case .invalid(let message):
            out(message)
            out(InteractiveCommand.usage)
            prompt()
        }
    }

    /// 結果行の直後・起動直後だけプロンプトを出す。notify は非同期に流れ続けるので、
    /// 毎回プロンプトを出し直すと画面が埋まってしまう。
    private func prompt() {
        guard interactiveStarted, !isQuitting else { return }
        promptPending = false
        // stdout は行バッファなので、改行の無いプロンプトは明示的に流す。
        print("> ", terminator: "")
        fflush(stdout)
        promptShown = true
    }

    /// 応答（write/read/notify 設定）が返ってきたらプロンプトを出す。
    /// 応答が来ないまま固まらないよう保険のタイマーも仕掛ける。
    private func deferPrompt(timeout: Double = 3.0) {
        guard interactiveStarted else { return }
        promptPending = true
        promptToken &+= 1
        let token = promptToken
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.promptPending, self.promptToken == token else { return }
            self.prompt()
        }
    }

    /// 応答ハンドラから呼ぶ。待っていた場合だけプロンプトを出す。
    fileprivate func promptIfWaiting() {
        if promptPending { prompt() }
    }

    fileprivate func quit(reason: String) {
        guard !isQuitting else { return }
        isQuitting = true
        out("[\(Timestamp.iso8601(Date()))] 切断して終了します (\(reason))")
        if let target {
            central.cancelPeripheralConnection(target)
        }
        if let path = logger.path { print("log: \(path)") }
        // cancelPeripheralConnection が実際に飛ぶ猶予を与えてから抜ける。
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.logger.close()
            exit(0)
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

        case .dump(let matcher, _, _, _):
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
        guard !isQuitting else { return }
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
            promptIfWaiting()
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
        promptIfWaiting()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if let error {
            out("notify 設定失敗 \(characteristic.uuid.uuidString): \(error.localizedDescription)")
        } else if promptPending {
            out("notify=\(characteristic.isNotifying) \(characteristic.uuid.uuidString)")
        }
        promptIfWaiting()
    }

    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        out("デバイス名が変わりました: \(peripheral.name ?? "(no name)")")
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        out("service が変更されました。再探索します。")
        startDiscovery(peripheral)
    }
}
