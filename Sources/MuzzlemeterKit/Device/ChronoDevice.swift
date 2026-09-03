import Foundation

/// 弾速計 1 台との付き合いをまとめた actor。
///
/// 責務:
/// - スキャン → 接続 → 購読 の状態機械
/// - 受信バイト列を `ChronoPacketDecoder` に通して `ChronoEvent` として配信
/// - 最後に接続した機器を覚えて **自動再接続**（公式アプリで一番不満が出やすい部分）
///
/// トランスポート（BLE / リプレイ）とデコーダ（プロトコル）の両方を差し替え可能に
/// してあるので、プロトコル未確定の今でもアプリ側を完成させられる。
public actor ChronoDevice {
    /// 鍵ハンドシェイク（`0x4B`）の詰め方。`docs/PROTOCOL.md` §4。
    public struct HandshakeOptions: Sendable {
        /// CCCD 有効化から最初の書き込みまでの待ち。AceSoft は 564 ms 待っていた。
        public var initialDelay: TimeInterval
        /// ACK を待つ時間。実測の応答は 55–63 ms なので 3 秒あれば十分。
        public var ackTimeout: TimeInterval
        /// タイムアウト時の再送回数。
        public var retryCount: Int
        /// 続けてコマンドを送るときの間隔。AceSoft は 300–360 ms 間隔だった。
        public var commandGap: TimeInterval
        /// ハンドシェイク後に現在の弾を読むか（best-effort）。
        public var readsCurrentAmmo: Bool
        /// ハンドシェイク後にバッテリーを読むか（**未検証コマンド**。best-effort）。
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
        /// スキャン時に絞り込むサービス UUID。AC6000 はサービスを広告しないので `nil`。
        public var serviceUUIDs: [UUID]?
        /// 機器名の部分一致フィルタ。AC6000 は `AC6000BT-xxxxxx`。
        public var nameFilter: String?
        /// 接続後に購読する characteristic。
        public var notifyCharacteristics: [UUID]
        /// コマンドの書き込み先。`nil` ならハンドシェイクを行わない。
        public var writeCharacteristic: UUID?
        /// 購読完了後に送る任意の初期化コマンド（ハンドシェイクより前に送られる）。
        public var initialWrites: [(characteristic: UUID, data: Data, withResponse: Bool)]
        /// 鍵ハンドシェイクの設定。`nil` で無効（テスト・デモ用）。
        public var handshake: HandshakeOptions?
        public var autoReconnect: Bool
        /// 再接続バックオフの初期値と上限。
        public var reconnectBaseDelay: TimeInterval
        public var reconnectMaxDelay: TimeInterval
        /// 再接続の最大試行回数。`nil` で無制限。
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

        /// AC6000 MKIII BT の実機設定（`docs/PROTOCOL.md` §12 のチェックリストどおり）。
        public static func ac6000(
            autoReconnect: Bool = true,
            handshake: HandshakeOptions? = HandshakeOptions()
        ) -> Configuration {
            Configuration(
                serviceUUIDs: nil,                       // サービスは広告されない
                nameFilter: ChronoUUIDs.primaryNamePrefix,
                notifyCharacteristics: [ChronoUUIDs.notifyCharacteristic],
                writeCharacteristic: ChronoUUIDs.writeCharacteristic,
                handshake: handshake,
                autoReconnect: autoReconnect
            )
        }
    }

    /// 「最後に繋いだ機器」を覚えるためのキー。
    public static let lastPeripheralKey = "muzzlemeter.lastPeripheralIdentifier"

    /// 機器ごとのチェックサム鍵を覚えるためのキー。
    ///
    /// 鍵は広告の manufacturer data から取れるのが基本だが、広告を取り逃した状態で
    /// 再接続する経路（`retrievePeripherals` 直結）では広告が手に入らない。
    /// そのため一度成立した鍵は peripheral ごとに永続化する。
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

    /// 直近に見つかった機器（未接続時にユーザーへ選択させるため）。
    ///
    /// 変わったときだけ `ChronoEvent.discovered` として配信する。UI はこの一覧を
    /// そのまま出せばよく、並べ替え（前回接続 → 電波の強い順）は `DiscoveryList` が決める。
    public private(set) var discovery = DiscoveryList()

    /// 見つかった機器の配列。`discovery.peripherals` の別名（既存の呼び出し向け）。
    public var discovered: [DiscoveredPeripheral] { discovery.peripherals }
    public private(set) var connectedPeripheral: UUID?

    public nonisolated let events: AsyncStream<ChronoEvent>
    private nonisolated let continuation: AsyncStream<ChronoEvent>.Continuation

    private var pumpTask: Task<Void, Never>?
    /// 購読〜ハンドシェイクを走らせるタスク（イベントポンプとは別に動く）。
    private var setupTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    /// ユーザーが明示的に切ったのか、勝手に切れたのかを区別する（前者では再接続しない）。
    private var stoppedIntentionally = false

    /// 現在のチェックサム鍵。広告 → 永続化値 → 0/0 の順に解決する。
    public private(set) var keys: DeviceKeys = .zero
    /// ACK 待ち。`handle(_:)` 側から解決される。
    private var handshakeContinuation: CheckedContinuation<Bool, Never>?
    private var handshakeTimeoutTask: Task<Void, Never>?
    /// この接続で `ACK(0x4B)` を見たか。
    ///
    /// ACK が「待ち始める前」に届くことがある（記録済みフレームを一気に流すリプレイ、
    /// あるいは実機で書き込み完了より先に通知が処理された場合）。取りこぼすと
    /// ハンドシェイクが無意味にタイムアウトするので、接続ごとにフラグで覚えておく。
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

    /// 覚えている「最後に接続した機器」。
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

    /// 覚えている機器を忘れる。以降のスキャンでは最初に見つかった機器に繋ぐ。
    ///
    /// 永続化した鍵も一緒に捨てる。機器を忘れたのに鍵だけ残っていると、別個体に
    /// 誤った鍵でハンドシェイクを試みることになるため。
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

    // MARK: - ライフサイクル

    /// トランスポートのイベント購読を始め、スキャンを開始する。
    public func start() async {
        stoppedIntentionally = false
        await startPumpIfNeeded()
        await beginScan()
    }

    /// 切断し、再接続もしない。イベントストリームは生きたまま。
    public func stop() async {
        stoppedIntentionally = true
        completeHandshake(false)
        setupTask?.cancel()
        setupTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        await transport.stopScan()
        await transport.disconnect()
        state = .idle
    }

    /// 完全に終了する。イベントストリームも閉じる。
    public func shutdown() async {
        stoppedIntentionally = true
        completeHandshake(false)
        setupTask?.cancel()
        setupTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        pumpTask?.cancel()
        pumpTask = nil
        await transport.shutdown()
        continuation.finish()
    }

    /// 特定の機器に繋ぐ（ユーザーがリストから選んだ場合）。
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

    // MARK: - トランスポートイベント

    private func handle(_ event: TransportEvent) async {
        switch event {
        case .discovered(let peripheral):
            // RSSI は広告ごとに動くので、**同じ機器でも上書きして最新にする**。
            // 変わっていなければイベントを流さない（毎秒 UI を作り直さないため）。
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
            // **別タスクで走らせる。**
            // ハンドシェイクは ACK（= 受信イベント）を待つが、この `handle(_:)` は
            // イベントポンプの中から呼ばれている。ここで待つとポンプが止まり、
            // 待っている当の ACK が永遠に届かない（デッドロック）。
            setupTask?.cancel()
            setupTask = Task { [weak self] in
                await self?.subscribeAndInitialize()
            }

        case .disconnected(_, let reason):
            connectedPeripheral = nil
            // 切断をまたいで半端なフレームが残らないようにする。
            (decoder as? MuzzlemeterDecoder)?.reset()
            completeHandshake(false)
            state = .disconnected(reason: reason)
            scheduleReconnectIfNeeded()

        case .subscribed:
            break

        case .value(let characteristic, let data):
            for decoded in decoder.decode(characteristic: characteristic, data: data) {
                observeForHandshake(decoded)
                continuation.yield(decoded)
            }

        case .failed(let reason):
            state = .disconnected(reason: reason)
            scheduleReconnectIfNeeded()
        }
    }

    private func autoConnectIfAppropriate(to peripheral: DiscoveredPeripheral) async {
        guard state == .scanning else { return }
        // 覚えている機器があればそれだけに繋ぐ。無ければ最初に見つかった機器。
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
            // ここでリプレイの再生が始まる（実 BLE では何もしない）。
            // **ハンドシェイクを待つ前に呼ぶ**のが重要で、記録済みフレームを流すだけの
            // トランスポートでも ACK が届き、実機と同じ経路でハンドシェイクが成立する。
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

    // MARK: - 鍵ハンドシェイク（0x4B）

    /// 鍵を決めて `0x4B` を送り、`ACK(0x4B)` を待つ。
    ///
    /// 鍵の解決順:
    /// 1. **広告の manufacturer data**（`00 05 08 <k1> <k2> …`）— 実機で成立を確認済み。
    ///    ボタン押下は不要で、55 ms ほどで ACK が返る。
    /// 2. 以前このペリフェラルで成立した鍵（`KeyValueStore`）— 広告を取り逃した再接続用。
    /// 3. `0/0` — 初回ペアリング。本体の電源ボタン押下が要り、`0x4B` 応答で鍵が返ってくる
    ///    （**未検証**）。この間 `.pairing` 状態のままにしてユーザーに操作を促す。
    private func performHandshake(options: HandshakeOptions, writeCharacteristic: UUID) async -> Bool {
        applyKeys(resolveKeys())

        // CCCD 有効化直後は本体が受け付けないことがあるので少し待つ（AceSoft は 564 ms）。
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

    /// ハンドシェイク後の best-effort な読み出し。失敗しても `.ready` を妨げない。
    private func runPostHandshakeQueries(options: HandshakeOptions, writeCharacteristic: UUID) async {
        var requests = [ChronoRequest]()
        if options.readsCurrentAmmo { requests.append(.readCurrentAmmo) }
        if options.readsBattery { requests.append(.readBattery) }
        for request in requests {
            await sleep(options.commandGap)
            // 応答が無くても構わない（バッテリーは未検証コマンド）。
            try? await transport.write(
                request.encoded(keys: keys),
                to: writeCharacteristic,
                withResponse: true
            )
        }
    }

    /// 受信イベントからハンドシェイクの成立を拾う。
    ///
    /// **予期しないフレームをエラーにしない**のが要点。本体は要求していない `0x47` / `0x5A` を
    /// 自発的に送ってくるので、ACK 待ちの最中に別のフレームが挟まっても無視して待ち続ける。
    private func observeForHandshake(_ event: ChronoEvent) {
        switch event {
        case .ack(let command) where command == ChronoCommand.readKey.rawValue:
            sawReadKeyAck = true
            completeHandshake(true)

        case .raw(_, let data):
            // 鍵未知のときの応答: `<aa> <L> 4b <k1> <k2> …`（data[3], data[4] が鍵）。
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
            // 本体の電源 OFF。約 0.76 秒後にリンクが落ちる（`docs/PROTOCOL.md` §5.1）。
            // エラーではないので再接続はトランスポートの切断イベントに任せる。
            completeHandshake(false)
            state = .disconnected(reason: "本体の電源が切れました")

        default:
            break
        }
    }

    private func waitForHandshakeAck(timeout: TimeInterval) async -> Bool {
        // 待ち始める前に届いていた ACK を取りこぼさない。
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

    // MARK: - 自動再接続

    private func scheduleReconnectIfNeeded() {
        guard configuration.autoReconnect, !stoppedIntentionally else { return }
        if let limit = configuration.maxReconnectAttempts, reconnectAttempt >= limit { return }
        guard reconnectTask == nil else { return }

        let attempt = reconnectAttempt
        reconnectAttempt += 1
        // 指数バックオフ: base * 2^attempt（上限あり）。
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
                // 直接接続に失敗したらスキャンからやり直す。
            }
        }
        await beginScan()
    }
}
