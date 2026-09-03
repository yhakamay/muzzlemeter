import Foundation

/// The actor that manages the relationship with one chronograph.
///
/// Responsibilities:
/// - The scan -> connect -> subscribe state machine
/// - Running received bytes through `ChronoPacketDecoder` and delivering them as
///   `ChronoEvent`
/// - Remembering the last-connected device and **auto-reconnecting** (the part users
///   complain about most with the official app)
///
/// Both the transport (BLE / replay) and the decoder (protocol) are swappable, so the
/// app side can be finished even before the protocol is fully confirmed.
public actor ChronoDevice {
    /// How the key handshake (`0x4B`) is paced. `docs/PROTOCOL.md` §4.
    public struct HandshakeOptions: Sendable {
        /// The wait from CCCD enable to the first write. AceSoft waited 564 ms.
        public var initialDelay: TimeInterval
        /// How long to wait for the ACK. Measured responses take 55-63 ms, so 3 seconds
        /// is plenty.
        public var ackTimeout: TimeInterval
        /// How many times to retry on timeout.
        public var retryCount: Int
        /// The gap between consecutive commands. AceSoft used a 300-360 ms interval.
        public var commandGap: TimeInterval
        /// Whether to read the current BB after the handshake (best-effort).
        public var readsCurrentAmmo: Bool
        /// Whether to read the battery after the handshake (**unverified command**;
        /// best-effort).
        public var readsBattery: Bool

        public init(
            initialDelay: TimeInterval = 0.5,
            ackTimeout: TimeInterval = 3.0,
            retryCount: Int = 1,
            commandGap: TimeInterval = 0.3,
            readsCurrentAmmo: Bool = true,
            readsBattery: Bool = false
        ) {
            self.initialDelay = initialDelay
            self.ackTimeout = ackTimeout
            self.retryCount = retryCount
            self.commandGap = commandGap
            self.readsCurrentAmmo = readsCurrentAmmo
            self.readsBattery = readsBattery
        }
    }

    public struct Configuration: Sendable {
        /// The service UUIDs to filter on while scanning. `nil` since the AC6000 doesn't
        /// advertise a service.
        public var serviceUUIDs: [UUID]?
        /// A partial match filter on the device name. The AC6000 is `AC6000BT-xxxxxx`.
        public var nameFilter: String?
        /// The characteristics subscribed to after connecting.
        public var notifyCharacteristics: [UUID]
        /// The characteristic commands are written to. `nil` means no handshake is
        /// performed.
        public var writeCharacteristic: UUID?
        /// Optional initialization commands sent once subscription completes (sent
        /// before the handshake).
        public var initialWrites: [(characteristic: UUID, data: Data, withResponse: Bool)]
        /// The key handshake settings. `nil` disables it (for tests / demos).
        public var handshake: HandshakeOptions?
        public var autoReconnect: Bool
        /// The initial value and cap for reconnect backoff.
        public var reconnectBaseDelay: TimeInterval
        public var reconnectMaxDelay: TimeInterval
        /// The maximum number of reconnect attempts. `nil` for unlimited.
        public var maxReconnectAttempts: Int?

        public init(
            serviceUUIDs: [UUID]? = nil,
            nameFilter: String? = nil,
            notifyCharacteristics: [UUID] = [],
            writeCharacteristic: UUID? = nil,
            initialWrites: [(characteristic: UUID, data: Data, withResponse: Bool)] = [],
            handshake: HandshakeOptions? = nil,
            autoReconnect: Bool = true,
            reconnectBaseDelay: TimeInterval = 1.0,
            reconnectMaxDelay: TimeInterval = 30.0,
            maxReconnectAttempts: Int? = nil
        ) {
            self.serviceUUIDs = serviceUUIDs
            self.nameFilter = nameFilter
            self.notifyCharacteristics = notifyCharacteristics
            self.writeCharacteristic = writeCharacteristic
            self.initialWrites = initialWrites
            self.handshake = handshake
            self.autoReconnect = autoReconnect
            self.reconnectBaseDelay = reconnectBaseDelay
            self.reconnectMaxDelay = reconnectMaxDelay
            self.maxReconnectAttempts = maxReconnectAttempts
        }

        /// The real-hardware configuration for the AC6000 MKIII BT (matches the checklist
        /// in `docs/PROTOCOL.md` §12).
        public static func ac6000(
            autoReconnect: Bool = true,
            handshake: HandshakeOptions? = HandshakeOptions()
        ) -> Configuration {
            Configuration(
                serviceUUIDs: nil,                       // No service is advertised
                nameFilter: ChronoUUIDs.primaryNamePrefix,
                notifyCharacteristics: [ChronoUUIDs.notifyCharacteristic],
                writeCharacteristic: ChronoUUIDs.writeCharacteristic,
                handshake: handshake,
                autoReconnect: autoReconnect
            )
        }
    }

    /// The key used to remember "the last connected device."
    public static let lastPeripheralKey = "muzzlemeter.lastPeripheralIdentifier"

    /// The key used to remember each device's own checksum key.
    ///
    /// The key normally comes from the advertisement's manufacturer data, but on the
    /// reconnect path that skips advertisements (going straight through
    /// `retrievePeripherals`), there's no advertisement to read it from. Because of that,
    /// once a key is established it's persisted per peripheral.
    public static func keysKey(for peripheral: UUID) -> String {
        "muzzlemeter.deviceKeys.\(peripheral.uuidString)"
    }

    private let transport: any ChronoTransport
    private let decoder: any ChronoPacketDecoder
    private let store: any KeyValueStore
    private var configuration: Configuration

    public private(set) var state: ConnectionState = .idle {
        didSet {
            guard state != oldValue else { return }
            continuation.yield(.connectionState(state))
        }
    }

    /// The most recently discovered devices (so the user can choose one before
    /// connecting).
    ///
    /// Delivered as `ChronoEvent.discovered` only when it changes. The UI can display
    /// this list as-is; the ordering (last-connected first, then by signal strength) is
    /// decided by `DiscoveryList`.
    public private(set) var discovery = DiscoveryList()

    /// The array of discovered devices. An alias for `discovery.peripherals` (for
    /// existing call sites).
    public var discovered: [DiscoveredPeripheral] { discovery.peripherals }
    public private(set) var connectedPeripheral: UUID?

    public nonisolated let events: AsyncStream<ChronoEvent>
    private nonisolated let continuation: AsyncStream<ChronoEvent>.Continuation

    private var pumpTask: Task<Void, Never>?
    /// The task that runs subscribe-through-handshake (runs separately from the event
    /// pump).
    private var setupTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    /// Distinguishes whether the user explicitly disconnected, or it dropped on its own
    /// (no reconnect in the former case).
    private var stoppedIntentionally = false

    /// The current checksum key. Resolved in order: advertisement -> persisted value ->
    /// 0/0.
    public private(set) var keys: DeviceKeys = .zero
    /// The pending ACK wait. Resolved from the `handle(_:)` side.
    private var handshakeContinuation: CheckedContinuation<Bool, Never>?
    private var handshakeTimeoutTask: Task<Void, Never>?
    /// Whether `ACK(0x4B)` has been seen for this connection.
    ///
    /// The ACK can arrive **before waiting for it starts** (e.g. a replay that plays back
    /// recorded frames all at once, or on real hardware if the notification is processed
    /// before the write completes). Missing it would make the handshake time out for no
    /// reason, so it's remembered in a flag for each connection.
    private var sawReadKeyAck = false

    public init(
        transport: any ChronoTransport,
        decoder: any ChronoPacketDecoder = PassthroughDecoder(),
        store: any KeyValueStore = InMemoryKeyValueStore(),
        configuration: Configuration = Configuration()
    ) {
        self.transport = transport
        self.decoder = decoder
        self.store = store
        self.configuration = configuration
        let (stream, continuation) = AsyncStream<ChronoEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = continuation
    }

    /// The remembered "last connected device."
    public var rememberedPeripheral: UUID? {
        store.uuid(forKey: Self.lastPeripheralKey)
    }

    public var autoReconnect: Bool { configuration.autoReconnect }

    public func setAutoReconnect(_ enabled: Bool) {
        configuration.autoReconnect = enabled
        if !enabled {
            reconnectTask?.cancel()
            reconnectTask = nil
        }
    }

    /// Forgets the remembered device. Future scans connect to whichever device is found
    /// first instead.
    ///
    /// Also discards the persisted key. If the device were forgotten but the key kept
    /// around, a handshake could be attempted against a different unit with the wrong key.
    public func forgetDevice() {
        if let remembered = rememberedPeripheral {
            store.set(nil as String?, forKey: Self.keysKey(for: remembered))
        }
        if let connected = connectedPeripheral {
            store.set(nil as String?, forKey: Self.keysKey(for: connected))
        }
        store.set(nil as String?, forKey: Self.lastPeripheralKey)
        keys = .zero
    }

    // MARK: - Lifecycle

    /// Starts subscribing to transport events and begins scanning.
    public func start() async {
        stoppedIntentionally = false
        await startPumpIfNeeded()
        await beginScan()
    }

    /// Disconnects and doesn't reconnect. The event stream stays alive.
    public func stop() async {
        stoppedIntentionally = true
        completeHandshake(false)
        abortLogRead()
        setupTask?.cancel()
        setupTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        await transport.stopScan()
        await transport.disconnect()
        state = .idle
    }

    /// Shuts down completely. Also closes the event stream.
    public func shutdown() async {
        stoppedIntentionally = true
        completeHandshake(false)
        abortLogRead()
        setupTask?.cancel()
        setupTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        pumpTask?.cancel()
        pumpTask = nil
        await transport.shutdown()
        continuation.finish()
    }

    /// Connects to a specific device (when the user picked one from the list).
    public func connect(to peripheral: UUID) async {
        stoppedIntentionally = false
        await startPumpIfNeeded()
        await transport.stopScan()
        state = .connecting
        do {
            try await transport.connect(to: peripheral)
        } catch {
            state = .disconnected(reason: "\(error)")
            scheduleReconnectIfNeeded()
        }
    }

    private func startPumpIfNeeded() async {
        guard pumpTask == nil else { return }
        let stream = await transport.events
        pumpTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func beginScan() async {
        discovery.removeAll()
        discovery.rememberedID = rememberedPeripheral
        continuation.yield(.discovered(discovery))
        state = .scanning
        do {
            try await transport.scan(
                services: configuration.serviceUUIDs,
                nameFilter: configuration.nameFilter
            )
        } catch {
            state = .disconnected(reason: "スキャンを開始できません: \(error)")
            scheduleReconnectIfNeeded()
        }
    }

    // MARK: - Transport events

    private func handle(_ event: TransportEvent) async {
        switch event {
        case .discovered(let peripheral):
            // RSSI moves with every advertisement, so **overwrite even for the same
            // device to keep it current**. No event is delivered if nothing changed
            // (so the UI isn't rebuilt every second).
            discovery.rememberedID = rememberedPeripheral
            if discovery.upsert(peripheral) {
                continuation.yield(.discovered(discovery))
            }
            await autoConnectIfAppropriate(to: peripheral)

        case .connected(let peripheral):
            connectedPeripheral = peripheral
            reconnectAttempt = 0
            sawReadKeyAck = false
            store.set(peripheral, forKey: Self.lastPeripheralKey)
            await transport.stopScan()
            // **Run this in a separate task.**
            // The handshake waits for an ACK (i.e. a received event), but this
            // `handle(_:)` is itself being called from inside the event pump. Waiting
            // here would stall the pump, and the very ACK being waited for would never
            // arrive (deadlock).
            setupTask?.cancel()
            setupTask = Task { [weak self] in
                await self?.subscribeAndInitialize()
            }

        case .disconnected(_, let reason):
            connectedPeripheral = nil
            // Make sure no half-built frame survives across the disconnect.
            (decoder as? MuzzlemeterDecoder)?.reset()
            completeHandshake(false)
            // Wake up any readout that's waiting on a response (don't leave it hanging).
            abortLogRead()
            state = .disconnected(reason: reason)
            scheduleReconnectIfNeeded()

        case .subscribed:
            break

        case .value(let characteristic, let data):
            for decoded in decoder.decode(characteristic: characteristic, data: data) {
                observeForHandshake(decoded)
                observeForLogRead(decoded)
                continuation.yield(decoded)
            }

        case .failed(let reason):
            state = .disconnected(reason: reason)
            scheduleReconnectIfNeeded()
        }
    }

    private func autoConnectIfAppropriate(to peripheral: DiscoveredPeripheral) async {
        guard state == .scanning else { return }
        // If a device is remembered, only connect to that one. Otherwise, whichever is
        // found first.
        if let remembered = rememberedPeripheral, remembered != peripheral.id { return }
        state = .connecting
        do {
            try await transport.connect(to: peripheral.id)
        } catch {
            state = .scanning
        }
    }

    private func subscribeAndInitialize() async {
        state = .pairing
        do {
            for characteristic in configuration.notifyCharacteristics {
                try await transport.subscribe(to: characteristic)
            }
            for write in configuration.initialWrites {
                try await transport.write(
                    write.data,
                    to: write.characteristic,
                    withResponse: write.withResponse
                )
            }
            // Replay playback starts here (a no-op for real BLE).
            // **Calling this before waiting for the handshake matters** — even a
            // transport that just plays back recorded frames delivers an ACK this way,
            // so the handshake completes through the same path as on real hardware.
            await transport.finishSetup()

            if let options = configuration.handshake, let writeCharacteristic = configuration.writeCharacteristic {
                guard await performHandshake(options: options, writeCharacteristic: writeCharacteristic) else {
                    state = .disconnected(
                        reason: "鍵ハンドシェイク（0x4B）に応答がありません。本体の電源を入れ直すか、"
                            + "本体の電源ボタンを押してペアリングを許可してください。"
                    )
                    await transport.disconnect()
                    scheduleReconnectIfNeeded()
                    return
                }
                await runPostHandshakeQueries(options: options, writeCharacteristic: writeCharacteristic)
            }
            state = .ready
        } catch {
            state = .disconnected(reason: "購読に失敗しました: \(error)")
            scheduleReconnectIfNeeded()
        }
    }

    // MARK: - Key handshake (0x4B)

    /// Resolves the key, sends `0x4B`, and waits for `ACK(0x4B)`.
    ///
    /// Key resolution order:
    /// 1. **The advertisement's manufacturer data** (`00 05 08 <k1> <k2> ...`) — confirmed
    ///    to work on real hardware. No button press needed; the ACK returns in about
    ///    55 ms.
    /// 2. A key previously established for this peripheral (`KeyValueStore`) — for
    ///    reconnects that skipped the advertisement.
    /// 3. `0/0` — first-time pairing. Requires pressing the device's power button, after
    ///    which the key is said to come back in the `0x4B` response (**unverified**).
    ///    Stays in the `.pairing` state throughout, prompting the user to act.
    private func performHandshake(options: HandshakeOptions, writeCharacteristic: UUID) async -> Bool {
        applyKeys(resolveKeys())

        // The device may not accept writes right after CCCD is enabled, so wait a bit
        // (AceSoft waited 564 ms).
        await sleep(options.initialDelay)

        for attempt in 0...max(0, options.retryCount) {
            if attempt > 0 { await sleep(options.commandGap) }
            let payload = ChronoRequest.readKey(keys).encoded(keys: keys)
            do {
                try await transport.write(payload, to: writeCharacteristic, withResponse: true)
            } catch {
                state = .disconnected(reason: "ハンドシェイクを送信できません: \(error)")
                return false
            }
            if await waitForHandshakeAck(timeout: options.ackTimeout) {
                persistKeys()
                return true
            }
        }
        return false
    }

    /// Best-effort reads after the handshake. A failure here doesn't block reaching
    /// `.ready`.
    private func runPostHandshakeQueries(options: HandshakeOptions, writeCharacteristic: UUID) async {
        var requests = [ChronoRequest]()
        if options.readsCurrentAmmo { requests.append(.readCurrentAmmo) }
        if options.readsBattery { requests.append(.readBattery) }
        for request in requests {
            await sleep(options.commandGap)
            // It's fine if there's no response (battery is an unverified command).
            try? await transport.write(
                request.encoded(keys: keys),
                to: writeCharacteristic,
                withResponse: true
            )
        }
    }

    /// Picks up handshake completion from received events.
    ///
    /// The key point: **an unexpected frame is never treated as an error.** The device
    /// sends `0x47` / `0x5A` spontaneously without being asked, so if one of those shows
    /// up while waiting for the ACK, it's ignored and the wait continues.
    private func observeForHandshake(_ event: ChronoEvent) {
        switch event {
        case .ack(let command) where command == ChronoCommand.readKey.rawValue:
            sawReadKeyAck = true
            completeHandshake(true)

        case .raw(_, let data):
            // The response when the key is unknown: `<aa> <L> 4b <k1> <k2> ...` (the key
            // is in data[3], data[4]).
            let bytes = [UInt8](data)
            guard bytes.count >= 5, bytes[0] == ChronoFrame.header,
                  bytes[2] == ChronoCommand.readKey.rawValue
            else { return }
            let received = DeviceKeys(key1: bytes[3], key2: bytes[4])
            guard !received.isZero else { return }
            applyKeys(received)
            sawReadKeyAck = true
            completeHandshake(true)

        case .powerOff:
            // The device powered off. The link drops about 0.76 s later
            // (`docs/PROTOCOL.md` §5.1). Not an error, so reconnecting is left to the
            // transport's own disconnect event.
            completeHandshake(false)
            state = .disconnected(reason: "本体の電源が切れました")

        default:
            break
        }
    }

    private func waitForHandshakeAck(timeout: TimeInterval) async -> Bool {
        // Don't miss an ACK that arrived before the wait started.
        if sawReadKeyAck { return true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            handshakeContinuation = continuation
            handshakeTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.completeHandshake(false)
            }
        }
    }

    private func completeHandshake(_ success: Bool) {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        guard let continuation = handshakeContinuation else { return }
        handshakeContinuation = nil
        continuation.resume(returning: success)
    }

    private func resolveKeys() -> DeviceKeys {
        if let peripheral = connectedPeripheral {
            if let advertised = discovery.peripherals.first(where: { $0.id == peripheral })?.keys {
                return advertised
            }
            if let stored = store.string(forKey: Self.keysKey(for: peripheral)),
               let keys = DeviceKeys(hexString: stored) {
                return keys
            }
        }
        return .zero
    }

    private func applyKeys(_ keys: DeviceKeys) {
        self.keys = keys
        (decoder as? any ChronoKeyAwareDecoder)?.updateKeys(keys)
    }

    private func persistKeys() {
        guard let peripheral = connectedPeripheral, !keys.isZero else { return }
        store.set(keys.hexString, forKey: Self.keysKey(for: peripheral))
    }

    private func sleep(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - Reading the device's internal log (0x62 / 0x63)
    //
    // Warning: **never send `0x61` (CLEAR_LOG).** No builder is provided for it either
    //    (`ChronoRequest`). It must not be sent until the readout is fully confirmed,
    //    and even once it is, an erase feature isn't needed.

    /// Never run another readout while a log readout is in progress (it would break the
    /// request/response pairing).
    private var isReadingLog = false
    private var logCountContinuation: CheckedContinuation<Int?, Never>?
    private var logCountTimeoutTask: Task<Void, Never>?
    private var logRecordContinuation: CheckedContinuation<DeviceLogRecordResponse?, Never>?
    private var logRecordTimeoutTask: Task<Void, Never>?

    /// One `0x63` response (the index and raw payload it carried, plus the shot it
    /// parsed into if any).
    private struct DeviceLogRecordResponse: Sendable {
        let index: Int
        let payload: [UInt8]
        let shot: Shot?
        /// An all-zero record (end of log; §6.6).
        let isEmpty: Bool
    }

    /// Reads the device's internal log record count (`0x62`). `nil` if there's no
    /// response.
    ///
    /// **Best-effort.** A failure here doesn't affect the connection or measurement.
    public func readLogCount(timeout: TimeInterval = 3.0) async -> Int? {
        guard state.isReady, let writeCharacteristic = configuration.writeCharacteristic else {
            return nil
        }
        guard !isReadingLog else { return nil }
        isReadingLog = true
        defer { isReadingLog = false }
        return await requestLogCount(timeout: timeout, writeCharacteristic: writeCharacteristic)
    }

    /// Reads the count, then reads records one at a time.
    ///
    /// The policy (based on the **confirmed-on-real-hardware** behavior in
    /// `docs/PROTOCOL.md` §6.6):
    /// * **One at a time, waiting for the response before sending the next.** The
    ///   response carries the index, so this could in principle be parallelized, but the
    ///   measured initialization sequence is followed instead: one request every
    ///   ~300 ms.
    /// * Reads from `options.startIndex` (default 1) through `count`. Since the log is
    ///   volatile, when the caller only wants to continue from last time, it advances
    ///   `startIndex` and passes that in.
    /// * Stops as soon as a record can't be parsed (unknown firmware variance). An
    ///   all-zero record (the "end of log" signature from §6.6) is **not an error — it's
    ///   a normal completion**.
    /// * Progress is reported incrementally via `progress` (so the UI isn't blocked).
    public func readDeviceLog(
        options: DeviceLogReadOptions = DeviceLogReadOptions(),
        progress: (@Sendable (DeviceLogProgress) -> Void)? = nil
    ) async -> DeviceLogReadResult {
        guard let writeCharacteristic = configuration.writeCharacteristic else {
            return DeviceLogReadResult(
                reportedCount: 0, records: [], outcome: .unavailable("書き込み先がありません")
            )
        }
        guard state.isReady else {
            return DeviceLogReadResult(
                reportedCount: 0, records: [], outcome: .unavailable("接続されていません")
            )
        }
        guard !isReadingLog else {
            return DeviceLogReadResult(
                reportedCount: 0, records: [], outcome: .unavailable("読み出し中です")
            )
        }
        isReadingLog = true
        defer { isReadingLog = false }

        guard let count = await requestLogCount(
            timeout: options.responseTimeout,
            writeCharacteristic: writeCharacteristic
        ) else {
            return DeviceLogReadResult(reportedCount: 0, records: [], outcome: .timedOut(index: nil))
        }
        // The index is 1 byte (1-based), so 255 is the ceiling.
        let lastIndex = min(count, 255)
        let firstIndex = min(options.startIndex, lastIndex + 1)
        guard firstIndex <= lastIndex else {
            // Nothing new to add (already read up to this point).
            return DeviceLogReadResult(reportedCount: count, records: [], outcome: .completed)
        }
        let cappedLastIndex = min(lastIndex, firstIndex + max(0, options.maximumRecords) - 1)
        let total = cappedLastIndex - firstIndex + 1

        var records = [DeviceLogRecord]()
        for index in firstIndex...cappedLastIndex {
            await sleep(options.commandGap)
            do {
                try await transport.write(
                    ChronoRequest.readLogRecord(index: UInt8(index)).encoded(keys: keys),
                    to: writeCharacteristic,
                    withResponse: true
                )
            } catch {
                return DeviceLogReadResult(
                    reportedCount: count, records: records, outcome: .unavailable("\(error)")
                )
            }
            guard let response = await waitForLogRecord(timeout: options.responseTimeout) else {
                return DeviceLogReadResult(
                    reportedCount: count, records: records, outcome: .timedOut(index: index)
                )
            }
            guard !response.isEmpty else {
                // All-zero = end of log. Not an error (§6.6). Treated as a normal
                // completion for what's been read so far.
                return DeviceLogReadResult(reportedCount: count, records: records, outcome: .completed)
            }
            guard let shot = response.shot else {
                // A defensive fallback that shouldn't normally happen on real hardware
                // (unknown firmware variance).
                records.append(DeviceLogRecord(index: response.index, payload: response.payload, shot: nil))
                return DeviceLogReadResult(
                    reportedCount: count, records: records, outcome: .unsupportedFormat(index: index)
                )
            }
            records.append(DeviceLogRecord(index: response.index, payload: response.payload, shot: shot))
            progress?(DeviceLogProgress(done: records.count, total: total))
        }
        return DeviceLogReadResult(reportedCount: count, records: records, outcome: .completed)
    }

    private func requestLogCount(
        timeout: TimeInterval,
        writeCharacteristic: UUID
    ) async -> Int? {
        do {
            try await transport.write(
                ChronoRequest.readLogCount.encoded(keys: keys),
                to: writeCharacteristic,
                withResponse: true
            )
        } catch {
            return nil
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            logCountContinuation = continuation
            logCountTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.completeLogCount(nil)
            }
        }
    }

    private func waitForLogRecord(timeout: TimeInterval) async -> DeviceLogRecordResponse? {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<DeviceLogRecordResponse?, Never>) in
            logRecordContinuation = continuation
            logRecordTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.completeLogRecord(nil)
            }
        }
    }

    /// A temporary holding spot, held only between `.logRecordRaw` and
    /// `.logRecord` / `.logRecordEmpty`. The decoder returns these two for the same
    /// `0x63` response in order, **within the same `decode` call**, so there's no race
    /// on this temporary storage (`ChronoDevice` is an actor and processes each result
    /// from `decoder.decode` synchronously, one at a time, before moving to the next
    /// event).
    private var pendingLogRecordPayload: [UInt8]?

    /// Picks up readout responses from received events.
    ///
    /// Just like the handshake, **an unexpected frame is never a cause for alarm**. Even
    /// while a log readout is in progress, shots (`0x52`) and spontaneous notifications
    /// (`0x47` / `0x5A`) still arrive as normal — only the relevant ones are picked up.
    private func observeForLogRead(_ event: ChronoEvent) {
        switch event {
        case .logCount(let count):
            completeLogCount(count)
        case .logRecordRaw(_, let payload):
            pendingLogRecordPayload = payload
        case .logRecord(let index, let shot):
            let payload = pendingLogRecordPayload ?? []
            pendingLogRecordPayload = nil
            completeLogRecord(
                DeviceLogRecordResponse(index: index, payload: payload, shot: shot, isEmpty: false)
            )
        case .logRecordEmpty(let index):
            let payload = pendingLogRecordPayload ?? []
            pendingLogRecordPayload = nil
            completeLogRecord(
                DeviceLogRecordResponse(index: index, payload: payload, shot: nil, isEmpty: true)
            )
        case .raw(_, let data):
            // A `0x63` response that arrived while waiting, but fell short of the
            // minimum length (5 bytes) the decoder needs to parse it as a
            // `DeviceLogWireRecord` (a hedge against unknown firmware variance). The
            // frame itself (header/length/checksum) is valid, so it still arrives as
            // `.raw`.
            guard logRecordContinuation != nil else { break }
            let bytes = [UInt8](data)
            guard bytes.count >= 4, bytes[0] == ChronoFrame.header,
                  bytes[2] == ChronoCommand.logRecord.rawValue
            else { break }
            let payload = bytes.count > 4 ? Array(bytes[3..<(bytes.count - 1)]) : []
            let index = payload.first.map(Int.init) ?? -1
            completeLogRecord(
                DeviceLogRecordResponse(index: index, payload: payload, shot: nil, isEmpty: false)
            )
        case .powerOff:
            abortLogRead()
        default:
            break
        }
    }

    private func completeLogCount(_ count: Int?) {
        logCountTimeoutTask?.cancel()
        logCountTimeoutTask = nil
        guard let continuation = logCountContinuation else { return }
        logCountContinuation = nil
        continuation.resume(returning: count)
    }

    private func completeLogRecord(_ response: DeviceLogRecordResponse?) {
        logRecordTimeoutTask?.cancel()
        logRecordTimeoutTask = nil
        guard let continuation = logRecordContinuation else { return }
        logRecordContinuation = nil
        continuation.resume(returning: response)
    }

    private func abortLogRead() {
        completeLogCount(nil)
        completeLogRecord(nil)
    }

    // MARK: - Auto-reconnect

    private func scheduleReconnectIfNeeded() {
        guard configuration.autoReconnect, !stoppedIntentionally else { return }
        if let limit = configuration.maxReconnectAttempts, reconnectAttempt >= limit { return }
        guard reconnectTask == nil else { return }

        let attempt = reconnectAttempt
        reconnectAttempt += 1
        // Exponential backoff: base * 2^attempt (capped).
        let delay = min(
            configuration.reconnectMaxDelay,
            configuration.reconnectBaseDelay * pow(2.0, Double(attempt))
        )
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.performReconnect()
        }
    }

    private func performReconnect() async {
        reconnectTask = nil
        guard configuration.autoReconnect, !stoppedIntentionally else { return }
        if let remembered = rememberedPeripheral {
            state = .connecting
            do {
                try await transport.connect(to: remembered)
                return
            } catch {
                // If direct connection fails, start over from scanning.
            }
        }
        await beginScan()
    }
}
