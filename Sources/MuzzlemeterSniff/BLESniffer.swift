import MuzzlemeterKit
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
    let writeType: WriteTypePreference
}

/// `dump` サブコマンドの設定。
///
/// タプルの連想値だと、項目が増えるたびに `case .dump(_, _, _, _, let x, _)` の
/// アンダースコアの数を数えることになる。**構造体にして名前で読む。**
struct DumpOptions: Sendable {
    let matcher: PeripheralMatcher
    let writes: [PendingWrite]
    /// `--write` を連続で送るときの間隔（秒）。応答をどの write に対するものか
    /// 対応付けられるように、既定でも 0 にはしない。
    let writeDelay: Double
    /// `--write-type`。対話モードで種別を明示しなかった write の既定値。
    let writeType: WriteTypePreference
    /// 購読・初期 write 完了後に stdin から追加コマンドを受け付けるか。
    let interactive: Bool
    /// 広告の manufacturer data から鍵を取り出し、購読後に `0x4B` READ_KEY を
    /// 自動で送るか（`--handshake`）。
    let handshake: Bool
    /// ハンドシェイクの後に本体内ログ（`0x62` → `0x63`）を読み出すか（`--read-log`）。
    /// **`0x61`（消去）は決して送らない。**
    let readLog: Bool
}

/// 動作モード。
enum SniffMode: Sendable {
    case scan(seconds: Double)
    case dump(DumpOptions)
}

/// CoreBluetooth のデリゲートは専用の DispatchQueue 上で動く。
/// 内部状態の読み書きはすべてこのキュー上でのみ行うため `@unchecked Sendable`。
final class BLESniffer: NSObject, @unchecked Sendable {
    private let mode: SniffMode
    private let serviceFilter: [CBUUID]?
    private let logger: LogWriter
    private let queue = DispatchQueue(label: "com.yhakamay.muzzlemeter.sniff.ble")

    private var central: CBCentralManager!
    private var seenPeripherals = [UUID: Date]()
    /// 接続対象を強参照で保持しないと CoreBluetooth が解放してしまう。
    private var target: CBPeripheral?
    private var pendingServiceCount = 0
    private var pendingReads = Set<String>()
    private var lastPacketAt: Date?
    private var didStartSession = false

    /// 広告の manufacturer data から取り出したチェックサム鍵（`--handshake` 用）。
    /// 取れなければ 0/0 のまま。受信フレームの復号にも使う。
    private var keys: DeviceKeys = .zero

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

    // MARK: `--read-log` の状態（すべて `queue` 上でのみ触る）

    /// いま何の応答を待っているか。
    enum LogReadStep: Sendable, Equatable {
        case idle
        case awaitingCount
        case awaitingRecord(index: Int, total: Int)
    }
    /// 読み出しの進行状態。
    var logReadStep: LogReadStep = .idle
    /// 応答が来なかったときの打ち切りタイマーを、最新の要求だけに効かせる世代番号。
    var logReadToken = 0
    /// 受け取った `0x63` の生 payload（最後にまとめて出す）。
    var logRecordLines = [String]()

    /// dump の設定。scan モードでは nil。
    private var dumpOptions: DumpOptions? {
        if case .dump(let options) = mode { return options }
        return nil
    }

    /// `--write-delay`（秒）。dump 以外では使わない。
    private var writeDelay: Double { dumpOptions?.writeDelay ?? 0 }

    /// `--write-type`。対話モードで種別を明示しなかった write に使う。
    private var defaultWriteType: WriteTypePreference { dumpOptions?.writeType ?? .auto }

    /// `--handshake`。購読後に鍵付き `0x4B` を自動送信するか。
    private var wantsHandshake: Bool { dumpOptions?.handshake ?? false }

    /// `--read-log`。ハンドシェイク後に本体内ログを読み出すか。
    private var wantsLogRead: Bool { dumpOptions?.readLog ?? false }

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

                muzzlemeter-sniff: Bluetooth へのアクセスが OS に拒否されました (TCC)。
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

        case .dump(let options):
            switch options.matcher {
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
        guard let options = dumpOptions else { return }
        let delay = options.writeDelay
        // 購読が確定してから送るため少し待つ（AceSoft は CCCD 応答の 564 ms 後に送っていた）。
        queue.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            self.sendHandshakeIfNeeded(peripheral)
            let extra = self.wantsHandshake ? max(delay, 0.3) : 0
            self.queue.asyncAfter(deadline: .now() + extra) { [weak self] in
                guard let self else { return }
                // ログ読み出しは応答を待ちながら進むので、終わってから --write に移る。
                if self.wantsLogRead {
                    self.beginLogRead(on: peripheral)
                } else {
                    self.runWrite(at: 0, of: options.writes, delay: delay, on: peripheral)
                }
            }
        }
    }

    /// ログ読み出しが終わった（または諦めた）ら、残りの `--write` と対話モードへ進む。
    private func finishLogRead(on peripheral: CBPeripheral) {
        guard let options = dumpOptions else { return }
        runWrite(at: 0, of: options.writes, delay: options.writeDelay, on: peripheral)
    }

    /// `--handshake`: 広告から取った鍵を載せた `0x4B` を write characteristic へ送る。
    ///
    /// 実機で確認済みの手順（`docs/PROTOCOL.md` §4.3）:
    /// `aa 06 4b <k1> <k2> <cks>` → 数十 ms 後に `aa 05 41 4b <cks>`（ACK）。
    /// 鍵が広告に載っていなければ 0/0 で送る（初回ペアリング。本体の電源ボタン押下が要る）。
    private func sendHandshakeIfNeeded(_ peripheral: CBPeripheral) {
        guard wantsHandshake else { return }
        let target = findCharacteristic(
            UUIDText.canonical(ChronoUUIDs.writeCharacteristic.uuidString),
            in: peripheral
        ) ?? defaultWriteCharacteristic(in: peripheral)
        guard let target else {
            out("handshake: 書き込める characteristic がありません（スキップ）")
            return
        }
        if keys.isZero {
            out("handshake: 広告に鍵が見つかりませんでした。0/0 で送ります（本体の電源ボタン押下が必要です）")
        } else {
            out("handshake: 広告から鍵を取得しました \(keys)")
        }
        // READ_KEY は鍵確立前のフレームなので 0/0 で署名される（ChronoRequest が面倒を見る）。
        _ = send(
            ChronoCommand.readKey(keys: keys),
            to: target,
            on: peripheral,
            preference: .with   // 実機の AceSoft は全フレームを Write Request で送っていた
        )
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
            _ = send(pending.payload, to: characteristic, on: peripheral, preference: pending.writeType)
        } else {
            out("write: \(pending.rawUUIDText) が見つかりません（スキップ）")
        }
        // 応答をどの write のものか対応付けられるよう、次の送信まで間隔を空ける。
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runWrite(at: index + 1, of: writes, delay: delay, on: peripheral)
        }
    }

    /// `--write-type` / `wr` / `wn` の指定を実際の `CBCharacteristicWriteType` に落とす。
    ///
    /// `auto` だけは characteristic のプロパティに従い、書けなければ nil（スキップ）を返す。
    /// `with` / `without` はプロパティに関わらず**強制する**。プロパティを正しく申告しない
    /// ファームウェアが相手でも試せることが、このオプションの存在理由だから。
    private func resolveWriteType(
        _ preference: WriteTypePreference,
        for characteristic: CBCharacteristic
    ) -> CBCharacteristicWriteType? {
        let props = characteristic.properties
        switch preference {
        case .auto:
            if props.contains(.write) { return .withResponse }
            if props.contains(.writeWithoutResponse) { return .withoutResponse }
            out("write: \(characteristic.uuid.uuidString) は書き込み不可（スキップ）")
            return nil
        case .with:
            if !props.contains(.write) {
                out("注意: \(characteristic.uuid.uuidString) は write プロパティを持ちませんが withResponse で送ります")
            }
            return .withResponse
        case .without:
            if !props.contains(.writeWithoutResponse) {
                out("注意: \(characteristic.uuid.uuidString) は writeWithoutResponse プロパティを持ちませんが withoutResponse で送ります")
            }
            return .withoutResponse
        }
    }

    /// 1 件送信して、応答を待つ必要がある（withResponse）かどうかを返す。
    private func send(
        _ payload: Data,
        to characteristic: CBCharacteristic,
        on peripheral: CBPeripheral,
        preference: WriteTypePreference
    ) -> Bool {
        guard let type = resolveWriteType(preference, for: characteristic) else { return false }
        let kind = (type == .withResponse) ? "withResponse" : "withoutResponse"
        out(
            "[\(Timestamp.iso8601(Date()))] write -> \(characteristic.uuid.uuidString) (\(kind)) len=\(payload.count) hex: \(Hex.string(payload))"
        )
        if let decoded = FrameDescription.describe(payload, keys: keys) {
            out("  -> \(decoded)")
        }
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

    /// 1 回の write で送れる最大バイト数。ATT_MTU の実測値として使える
    /// （withoutResponse は ATT_MTU-3、withResponse は最大 512 が返るのが普通）。
    /// フレームが途中で切れているのか、そもそも届いていないのかを切り分けるために出す。
    private func printMaximumWriteLengths(_ peripheral: CBPeripheral) {
        let withResponse = peripheral.maximumWriteValueLength(for: .withResponse)
        let withoutResponse = peripheral.maximumWriteValueLength(for: .withoutResponse)
        out("最大 write 長: withResponse=\(withResponse) bytes  withoutResponse=\(withoutResponse) bytes")
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
        guard dumpOptions?.interactive == true else { return }
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
        out("既定の write 種別: --write-type \(defaultWriteType.rawValue)（wr / wn で 1 回ずつ上書きできます）")
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
        thread.name = "muzzlemeter-sniff.stdin"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    private func handle(line: String) {
        // ユーザーが Enter を押した時点で端末側が改行しているので、プロンプトは消えている。
        promptShown = false

        let commands = InteractiveCommand.parseLine(line)
        guard !commands.isEmpty else {
            prompt()
            return
        }
        run(commands, at: 0)
    }

    /// `;` 区切りの複数コマンドを `--write-delay` 間隔で順に実行する。
    /// プロンプトは最後の 1 つが終わってから出す。
    private func run(_ commands: [InteractiveCommand], at index: Int) {
        guard !isQuitting, index < commands.count else { return }
        let waitsForResponse = execute(commands[index])

        guard index + 1 < commands.count else {
            if waitsForResponse {
                deferPrompt()
            } else {
                prompt()
            }
            return
        }
        // 応答をどのフレームのものか対応付けられるよう、--write と同じ間隔を空ける。
        queue.asyncAfter(deadline: .now() + writeDelay) { [weak self] in
            self?.run(commands, at: index + 1)
        }
    }

    /// 1 コマンドを実行し、非同期の応答（write/read/notify 設定）を待つ必要があるかを返す。
    /// プロンプトの出し入れは呼び出し側（`run`）の責任。
    private func execute(_ command: InteractiveCommand) -> Bool {
        switch command {
        case .none:
            return false

        case .help:
            out(InteractiveCommand.helpText)
            return false

        case .quit:
            quit(reason: "q")
            return false

        case .list:
            guard let peripheral = target else {
                out("未接続です。")
                return false
            }
            printGATTTree(peripheral)
            return false

        case .mtu:
            guard let peripheral = target else {
                out("未接続です。")
                return false
            }
            printMaximumWriteLengths(peripheral)
            return false

        case .write(let targetText, let payload, let type):
            guard let peripheral = target else {
                out("未接続です。")
                return false
            }
            let characteristic: CBCharacteristic?
            if let targetText {
                characteristic = resolveCharacteristic(targetText, in: peripheral)
            } else {
                characteristic = defaultWriteCharacteristic(in: peripheral)
                if characteristic == nil { out("書き込める characteristic がありません。") }
            }
            guard let characteristic else { return false }
            // 種別を明示していなければ --write-type に従う。
            return send(
                payload,
                to: characteristic,
                on: peripheral,
                preference: type ?? defaultWriteType
            )

        case .read(let targetText):
            guard let peripheral = target,
                let characteristic = resolveCharacteristic(targetText, in: peripheral)
            else {
                if target == nil { out("未接続です。") }
                return false
            }
            guard characteristic.properties.contains(.read) else {
                out("read 不可: \(characteristic.uuid.uuidString)")
                return false
            }
            pendingReads.insert(UUIDText.canonical(characteristic.uuid))
            peripheral.readValue(for: characteristic)
            return true  // didUpdateValueFor を待つ

        case .setNotify(let targetText, let enabled):
            guard let peripheral = target,
                let characteristic = resolveCharacteristic(targetText, in: peripheral)
            else {
                if target == nil { out("未接続です。") }
                return false
            }
            let props = characteristic.properties
            guard props.contains(.notify) || props.contains(.indicate) else {
                out("notify/indicate 不可: \(characteristic.uuid.uuidString)")
                return false
            }
            out("\(enabled ? "subscribe" : "unsubscribe"): \(characteristic.uuid.uuidString)")
            peripheral.setNotifyValue(enabled, for: characteristic)
            return true  // didUpdateNotificationStateFor を待つ

        case .invalid(let message):
            out(message)
            out(InteractiveCommand.usage)
            return false
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

        case .dump(let options):
            guard target == nil else { return }
            guard options.matcher.matches(peripheral: peripheral, advertisementData: advertisementData)
            else { return }
            central.stopScan()
            // 鍵は広告にしか載っていない。接続してからでは取れないのでここで拾う。
            if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
               let advertised = DeviceKeys(manufacturerData: mfg) {
                keys = advertised
            }
            target = peripheral
            out("見つかりました: \(describeAdvertisement(advertisementData, rssi: RSSI, peripheral: peripheral))")
            out("接続中…")
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        out("接続しました: \(peripheral.name ?? "(no name)") [\(peripheral.identifier.uuidString)]")
        printMaximumWriteLengths(peripheral)
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
        if let decoded = FrameDescription.describe(data, keys: keys) {
            out("  -> \(decoded)")
        }
        handleLogRead(data, on: peripheral)
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


// MARK: - --read-log（本体内ログの吸い上げ）

/// `0x62`（件数）→ `0x63`（1 件ずつ）を順に投げて、応答を生のまま書き出す。
///
/// **これが `0x63` の実物を手に入れる唯一の経路。** 応答レイアウトは 1 度も
/// 観測できていない（`docs/PROTOCOL.md` §6.6）ので、要求の形も応答の読み方も推定でしかない。
/// そのため:
/// * 読めない応答が返っても**止めずに最後まで読む**。サニファの仕事は解釈ではなく採取で、
///   1 件で止めると形式を推し量る材料が集まらない（アプリ側は逆に、嘘の数字を保存しないよう
///   最初の 1 件で止める）。
/// * 応答が来なければ数秒で諦めて先へ進む。**本体を待ち続けて操作不能にしない。**
/// * 🚫 `0x61`（CLEAR_LOG）は**絶対に送らない**。ビルダ自体が存在しない。
extension BLESniffer {
    /// 応答待ちの上限（秒）。実測の応答は 45–63 ms なので、これで足りなければ形式違い。
    private static let logReadTimeout: Double = 3.0

    func beginLogRead(on peripheral: CBPeripheral) {
        guard let characteristic = logWriteTarget(in: peripheral) else {
            out("read-log: 書き込める characteristic がありません（スキップ）")
            finishLogRead(on: peripheral)
            return
        }
        out("")
        out("=== --read-log: 本体内ログを読み出します（0x62 → 0x63。0x61 は送りません） ===")
        if keys.isZero {
            out("read-log: 注意 — 鍵が 0/0 です。--handshake を付けて鍵を確立してから読んでください。")
        }
        logRecordLines.removeAll()
        logReadStep = .awaitingCount
        _ = send(
            ChronoCommand.readLogCount(keys: keys),
            to: characteristic,
            on: peripheral,
            preference: .with
        )
        scheduleLogReadTimeout(on: peripheral)
    }

    /// 通知から読み出しの応答を拾う。関係の無いフレーム（射撃・自発通知）は素通りさせる。
    func handleLogRead(_ data: Data, on peripheral: CBPeripheral) {
        guard logReadStep != .idle else { return }
        let bytes = [UInt8](data)
        guard bytes.count >= ChronoFrame.minimumLength, bytes[0] == ChronoFrame.header else { return }
        let payload = Array(bytes[3..<(bytes.count - 1)])

        switch logReadStep {
        case .idle:
            return

        case .awaitingCount:
            guard bytes[2] == ChronoCommand.logCount.rawValue, payload.count >= 2 else { return }
            // payload = [status, count]（§6.5。BE16 説との区別は未検証）。
            let count = Int(payload[1])
            out("read-log: 本体内ログ \(count) 件")
            guard count > 0 else {
                out("read-log: 読み出すものがありません")
                endLogRead(on: peripheral)
                return
            }
            requestLogRecord(index: 0, total: count, on: peripheral)

        case .awaitingRecord(let index, let total):
            guard bytes[2] == ChronoCommand.logRecord.rawValue else { return }
            let hex = payload.map { String(format: "%02x", $0) }.joined(separator: " ")
            logRecordLines.append("\(index) \(hex)")
            if let report = FireReport.logRecord(payload: payload) {
                out(
                    String(
                        format: "read-log: record %d/%d rawSpeed=%d (%.2f m/s) rawRev=%d  payload: %@",
                        index, total, Int(report.rawSpeed), report.metersPerSecond,
                        Int(report.rawRev), hex
                    )
                )
            } else {
                // **ここが本命。** FIRE_REPORT の並びで読めない = 推定が外れている。
                out("read-log: record \(index)/\(total) 未知の形式  payload: \(hex)")
            }
            let next = index + 1
            guard next < total else {
                endLogRead(on: peripheral)
                return
            }
            requestLogRecord(index: next, total: total, on: peripheral)
        }
    }

    private func requestLogRecord(index: Int, total: Int, on peripheral: CBPeripheral) {
        guard let characteristic = logWriteTarget(in: peripheral) else {
            endLogRead(on: peripheral)
            return
        }
        logReadStep = .awaitingRecord(index: index, total: total)
        // 実測の初期化シーケンスに合わせて 1 本ずつ ~300 ms 間隔で送る（§4.2）。
        queue.asyncAfter(deadline: .now() + max(writeDelay, 0.3)) { [weak self] in
            guard let self, case .awaitingRecord(let waiting, _) = self.logReadStep,
                  waiting == index
            else { return }
            _ = self.send(
                ChronoCommand.readLogRecord(UInt16(clamping: index), keys: self.keys),
                to: characteristic,
                on: peripheral,
                preference: .with
            )
            self.scheduleLogReadTimeout(on: peripheral)
        }
    }

    private func scheduleLogReadTimeout(on peripheral: CBPeripheral) {
        logReadToken += 1
        let token = logReadToken
        queue.asyncAfter(deadline: .now() + Self.logReadTimeout) { [weak self] in
            guard let self, self.logReadToken == token, self.logReadStep != .idle else { return }
            switch self.logReadStep {
            case .awaitingCount:
                out("read-log: 0x62 に応答がありませんでした。")
            case .awaitingRecord(let index, _):
                out(
                    "read-log: 0x63 index=\(index) に応答がありませんでした。"
                        + "要求の形（payload = index LE16）が違う可能性があります（docs/PROTOCOL.md §6.6）。"
                )
            case .idle:
                break
            }
            self.endLogRead(on: peripheral)
        }
    }

    /// 採取したものをまとめて出してから、残りの `--write` と対話モードへ進む。
    private func endLogRead(on peripheral: CBPeripheral) {
        logReadStep = .idle
        logReadToken += 1
        if logRecordLines.isEmpty {
            out("read-log: 採取できたレコードはありません。")
        } else {
            out("")
            out("=== read-log: 採取した 0x63 の payload（1 行 = 1 レコード: <index> <hex>） ===")
            for line in logRecordLines { out(line) }
            out("=== ここまで。この部分をそのまま共有してください ===")
        }
        out("")
        finishLogRead(on: peripheral)
    }

    /// 書き込み先。実機の write characteristic を優先し、無ければ書ける最初のもの。
    private func logWriteTarget(in peripheral: CBPeripheral) -> CBCharacteristic? {
        findCharacteristic(
            UUIDText.canonical(ChronoUUIDs.writeCharacteristic.uuidString),
            in: peripheral
        ) ?? defaultWriteCharacteristic(in: peripheral)
    }
}
