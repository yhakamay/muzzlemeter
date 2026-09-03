import MuzzlemeterKit
@preconcurrency import CoreBluetooth
import Foundation

/// How the target to connect to is specified.
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

/// An initialization command to send.
struct PendingWrite: Sendable {
    let characteristicUUID: String  // normalized 128-bit string
    let payload: Data
    let rawUUIDText: String
    let writeType: WriteTypePreference
}

/// Settings for the `dump` subcommand.
///
/// With a tuple's associated values, every new field means counting underscores in
/// `case .dump(_, _, _, _, let x, _)`. **A struct read by name instead.**
struct DumpOptions: Sendable {
    let matcher: PeripheralMatcher
    let writes: [PendingWrite]
    /// The interval (seconds) between consecutive `--write`s. Never defaults to 0, so a
    /// response can be matched to the write that caused it.
    let writeDelay: Double
    /// `--write-type`. The default for a write in interactive mode that didn't specify a
    /// type explicitly.
    let writeType: WriteTypePreference
    /// Whether to accept further commands from stdin after subscribing and sending the
    /// initial writes.
    let interactive: Bool
    /// Whether to extract the key from the advertisement's manufacturer data and
    /// automatically send `0x4B` READ_KEY after subscribing (`--handshake`).
    let handshake: Bool
    /// Whether to read the device's internal log (`0x62` -> `0x63`) after the handshake
    /// (`--read-log`). **`0x61` (erase) is never sent.**
    let readLog: Bool
}

/// The operating mode.
enum SniffMode: Sendable {
    case scan(seconds: Double)
    case dump(DumpOptions)
}

/// CoreBluetooth delegate callbacks run on a dedicated DispatchQueue.
/// All reads/writes of internal state happen only on that queue, hence `@unchecked Sendable`.
final class BLESniffer: NSObject, @unchecked Sendable {
    private let mode: SniffMode
    private let serviceFilter: [CBUUID]?
    private let logger: LogWriter
    private let queue = DispatchQueue(label: "com.yhakamay.muzzlemeter.sniff.ble")

    private var central: CBCentralManager!
    private var seenPeripherals = [UUID: Date]()
    /// A strong reference to the connection target — without it, CoreBluetooth would
    /// deallocate it.
    private var target: CBPeripheral?
    private var pendingServiceCount = 0
    private var pendingReads = Set<String>()
    private var lastPacketAt: Date?
    private var didStartSession = false

    /// The checksum key extracted from the advertisement's manufacturer data (for
    /// `--handshake`). Stays 0/0 if it couldn't be read. Also used to decrypt received
    /// frames.
    private var keys: DeviceKeys = .zero

    // MARK: Interactive mode state (touched only on `queue`)

    /// Whether the stdin reader thread has already started (so a reconnect doesn't
    /// start a second one).
    private var interactiveStarted = false
    /// Whether the "> " prompt is on screen without a trailing newline yet.
    private var promptShown = false
    /// Waiting for a write / read result; show the prompt once it comes back.
    private var promptPending = false
    /// A generation number so the fallback timer for a missing response only fires for
    /// the latest request.
    private var promptToken = 0
    /// Currently shutting down via `q` / EOF. Suppresses reconnecting.
    private var isQuitting = false

    // MARK: `--read-log` state (touched only on `queue`)

    /// What response is currently being waited for.
    enum LogReadStep: Sendable, Equatable {
        case idle
        case awaitingCount
        case awaitingRecord(index: Int, total: Int)
    }
    /// The readout's progress.
    var logReadStep: LogReadStep = .idle
    /// A generation number so the give-up timer for a missing response only fires for
    /// the latest request.
    var logReadToken = 0
    /// The raw `0x63` payloads received (printed together at the end).
    var logRecordLines = [String]()

    /// The dump settings. `nil` in scan mode.
    private var dumpOptions: DumpOptions? {
        if case .dump(let options) = mode { return options }
        return nil
    }

    /// `--write-delay` (seconds). Unused outside of dump.
    private var writeDelay: Double { dumpOptions?.writeDelay ?? 0 }

    /// `--write-type`. Used for a write in interactive mode that didn't specify a type
    /// explicitly.
    private var defaultWriteType: WriteTypePreference { dumpOptions?.writeType ?? .auto }

    /// `--handshake`. Whether to automatically send the keyed `0x4B` after subscribing.
    private var wantsHandshake: Bool { dumpOptions?.handshake ?? false }

    /// `--read-log`. Whether to read the device's internal log after the handshake.
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

    /// Without Bluetooth TCC permission, CoreBluetooth prints nothing and kills the
    /// process with SIGABRT the moment `CBCentralManager` is created.
    /// This prints a hint explaining why, then restores the default handler.
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

    // MARK: - Output helpers

    private func out(_ line: String) {
        // If a notification arrives while the prompt is still showing, it would run
        // into it as "> [2026-...", so a newline is inserted first (the prompt itself
        // is never written to the log file).
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

    // MARK: - State

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

    // MARK: - Displaying scan results

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

    // MARK: - Post-connection processing

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

    /// Sends `--write` one at a time, spaced `writeDelay` apart, then enters interactive
    /// mode once done.
    private func performWrites(_ peripheral: CBPeripheral) {
        guard let options = dumpOptions else { return }
        let delay = options.writeDelay
        // Wait a bit before sending, since subscription needs to settle first (AceSoft
        // sent 564 ms after the CCCD response).
        queue.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            self.sendHandshakeIfNeeded(peripheral)
            let extra = self.wantsHandshake ? max(delay, 0.3) : 0
            self.queue.asyncAfter(deadline: .now() + extra) { [weak self] in
                guard let self else { return }
                // A log readout waits on responses as it proceeds, so it moves on to
                // --write only after it finishes.
                if self.wantsLogRead {
                    self.beginLogRead(on: peripheral)
                } else {
                    self.runWrite(at: 0, of: options.writes, delay: delay, on: peripheral)
                }
            }
        }
    }

    /// Once the log readout finishes (or gives up), moves on to the remaining
    /// `--write`s and interactive mode.
    private func finishLogRead(on peripheral: CBPeripheral) {
        guard let options = dumpOptions else { return }
        runWrite(at: 0, of: options.writes, delay: options.writeDelay, on: peripheral)
    }

    /// `--handshake`: sends `0x4B` carrying the key taken from the advertisement to the
    /// write characteristic.
    ///
    /// The procedure confirmed on real hardware (`docs/PROTOCOL.md` §4.3):
    /// `aa 06 4b <k1> <k2> <cks>` -> tens of ms later, `aa 05 41 4b <cks>` (ACK).
    /// If the advertisement doesn't carry a key, this sends 0/0 instead (first-time
    /// pairing, which requires pressing the device's power button).
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
        // READ_KEY is a pre-key-establishment frame, so it's signed with 0/0
        // (`ChronoRequest` handles this).
        _ = send(
            ChronoCommand.readKey(keys: keys),
            to: target,
            on: peripheral,
            preference: .with   // The real AceSoft app sent every frame as a Write Request
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
        // Space out until the next send, so a response can be matched to the write that
        // caused it.
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runWrite(at: index + 1, of: writes, delay: delay, on: peripheral)
        }
    }

    /// Resolves a `--write-type` / `wr` / `wn` choice into the actual
    /// `CBCharacteristicWriteType`.
    ///
    /// Only `auto` follows the characteristic's properties, returning nil (skip) if it
    /// can't be written to. `with` / `without` **force it regardless of the
    /// properties** — being able to try a firmware that doesn't declare its properties
    /// correctly is the whole reason this option exists.
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

    /// Sends one write, returning whether a response needs to be waited for
    /// (withResponse).
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

    /// Tries an exact match first (normalizing 16-bit / 32-bit short forms for
    /// comparison too), then falls back to a prefix match on the UUID string. Returns
    /// nil and prints the candidates if the match is ambiguous.
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

    /// The default write target. Prefers one with `write` (with response); falls back
    /// to the first with `writeWithoutResponse`.
    private func defaultWriteCharacteristic(in peripheral: CBPeripheral) -> CBCharacteristic? {
        let all = (peripheral.services ?? []).flatMap { $0.characteristics ?? [] }
        if let withResponse = all.first(where: { $0.properties.contains(.write) }) {
            return withResponse
        }
        return all.first { $0.properties.contains(.writeWithoutResponse) }
    }

    /// The maximum number of bytes sendable in one write. Usable as a measured ATT_MTU
    /// value (withoutResponse is typically ATT_MTU-3; withResponse usually reports up to
    /// 512). Printed to help tell whether a frame is being cut short mid-way, or not
    /// arriving at all.
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

// MARK: - Interactive mode

extension BLESniffer {
    /// Called once subscription and `--write` have finished. The stdin reader starts
    /// only once.
    private func startInteractiveIfNeeded(_ peripheral: CBPeripheral) {
        guard dumpOptions?.interactive == true else { return }
        guard !interactiveStarted else {
            // After a reconnect: reprint the default write target and return to the
            // prompt.
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

    /// `readLine()` blocks, so it runs on its own thread; BLE operations hop onto
    /// CoreBluetooth's queue. Internal state is always touched only on `queue`.
    private func startStdinReader() {
        // A human typing at a terminal is slow enough on its own, but a pipe or
        // redirect can dump every line in an instant, sending writes back-to-back. This
        // paces reads at the same interval as --write.
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
            // Wait a bit before quitting, so the last command's response has a chance to
            // print first.
            Thread.sleep(forTimeInterval: max(pacing, 0.2))
            self.queue.async { self.quit(reason: "EOF") }
        }
        thread.name = "muzzlemeter-sniff.stdin"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    private func handle(line: String) {
        // The terminal already printed a newline when the user pressed Enter, so the
        // prompt is already gone.
        promptShown = false

        let commands = InteractiveCommand.parseLine(line)
        guard !commands.isEmpty else {
            prompt()
            return
        }
        run(commands, at: 0)
    }

    /// Runs `;`-separated commands in order, spaced `--write-delay` apart.
    /// The prompt is shown only once the last one finishes.
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
        // Space out the same as --write, so a response can be matched to the frame that
        // caused it.
        queue.asyncAfter(deadline: .now() + writeDelay) { [weak self] in
            self?.run(commands, at: index + 1)
        }
    }

    /// Runs one command, returning whether an asynchronous response (write/read/notify
    /// setting) needs to be waited for. Showing/hiding the prompt is the caller's
    /// (`run`'s) responsibility.
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
            // Falls back to --write-type when the type wasn't specified explicitly.
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
            return true  // wait for didUpdateValueFor

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
            return true  // wait for didUpdateNotificationStateFor

        case .invalid(let message):
            out(message)
            out(InteractiveCommand.usage)
            return false
        }
    }

    /// Shows the prompt only right after a result line, or right after startup. Since
    /// notifications keep streaming in asynchronously, reprinting the prompt every time
    /// would flood the screen.
    private func prompt() {
        guard interactiveStarted, !isQuitting else { return }
        promptPending = false
        // stdout is line-buffered, so a prompt with no trailing newline needs to be
        // flushed explicitly.
        print("> ", terminator: "")
        fflush(stdout)
        promptShown = true
    }

    /// Shows the prompt once a response (write/read/notify setting) comes back.
    /// Also arms a fallback timer so it doesn't hang forever waiting for one.
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

    /// Called from a response handler. Shows the prompt only if it was being waited for.
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
        // Give cancelPeripheralConnection a moment to actually go out before exiting.
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
            // The key only appears in the advertisement — it can't be recovered after
            // connecting, so it's picked up here.
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


// MARK: - --read-log (pulling the device's internal log)

/// Sends `0x62` (count) -> `0x63` (one at a time, 1-based index) in sequence and writes
/// out the raw responses.
///
/// Reads using the **format confirmed on real hardware**
/// (`docs/PROTOCOL.md` §6.5 / §6.6, from on-device testing on 2026-09-03/04). Because of
/// that:
/// * Even if an unparseable response comes back, **it keeps reading to the end without
///   stopping**. The sniffer's job is collection, not interpretation — stopping at the
///   first one wouldn't gather enough material to work out unknown firmware variance
///   (the app, conversely, stops at the first one so it never saves a false number).
/// * If no response arrives, it gives up after a few seconds and moves on. **It never
///   locks up waiting on the device.**
/// * `0x61` (CLEAR_LOG) is **never sent under any circumstances**. No builder for it
///   even exists.
extension BLESniffer {
    /// The upper bound on waiting for a response (seconds). Measured responses take
    /// 45-63 ms, so if this isn't enough the format must be different.
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

    /// Picks the readout's response out of notifications. Unrelated frames (shots,
    /// spontaneous notifications) pass straight through.
    func handleLogRead(_ data: Data, on peripheral: CBPeripheral) {
        guard logReadStep != .idle else { return }
        let bytes = [UInt8](data)
        guard bytes.count >= ChronoFrame.minimumLength, bytes[0] == ChronoFrame.header else { return }
        let payload = Array(bytes[3..<(bytes.count - 1)])

        switch logReadStep {
        case .idle:
            return

        case .awaitingCount:
            guard bytes[2] == ChronoCommand.logCount.rawValue, payload.count >= 1 else { return }
            // payload = [count, fixed 0x01] (§6.5, confirmed on real hardware).
            let count = Int(payload[0])
            out("read-log: 本体内ログ \(count) 件")
            guard count > 0 else {
                out("read-log: 読み出すものがありません")
                endLogRead(on: peripheral)
                return
            }
            // The index is 1-based. No response for 0 (confirmed on real hardware).
            requestLogRecord(index: 1, total: count, on: peripheral)

        case .awaitingRecord(let index, let total):
            guard bytes[2] == ChronoCommand.logRecord.rawValue else { return }
            let hex = payload.map { String(format: "%02x", $0) }.joined(separator: " ")
            logRecordLines.append("\(index) \(hex)")
            if let record = DeviceLogWireRecord(payload: payload), !record.isEmpty {
                out(
                    String(
                        format: "read-log: record %d/%d rawSpeed=%d (%.2f m/s) rawRev=%d  payload: %@",
                        index, total, Int(record.rawSpeed), record.metersPerSecond,
                        Int(record.rawRateOfFire), hex
                    )
                )
            } else if let record = DeviceLogWireRecord(payload: payload), record.isEmpty {
                out("read-log: record \(index)/\(total) 全ゼロ（ログの終端。エラーではありません）  payload: \(hex)")
            } else {
                out("read-log: record \(index)/\(total) 未知の形式  payload: \(hex)")
            }
            let next = index + 1
            guard next <= total else {
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
        // Sends one at a time, ~300 ms apart, matching the measured initialization
        // sequence (§4.2).
        queue.asyncAfter(deadline: .now() + max(writeDelay, 0.3)) { [weak self] in
            guard let self, case .awaitingRecord(let waiting, _) = self.logReadStep,
                  waiting == index
            else { return }
            _ = self.send(
                ChronoCommand.readLogRecord(UInt8(clamping: index), keys: self.keys),
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
                out("read-log: 0x63 index=\(index) に応答がありませんでした。")
            case .idle:
                break
            }
            self.endLogRead(on: peripheral)
        }
    }

    /// Prints everything collected together, then moves on to the remaining `--write`s
    /// and interactive mode.
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

    /// The write target. Prefers the real hardware's write characteristic; falls back to
    /// the first writable one.
    private func logWriteTarget(in peripheral: CBPeripheral) -> CBCharacteristic? {
        findCharacteristic(
            UUIDText.canonical(ChronoUUIDs.writeCharacteristic.uuidString),
            in: peripheral
        ) ?? defaultWriteCharacteristic(in: peripheral)
    }
}
