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
    public struct Configuration: Sendable {
        /// スキャン時に絞り込むサービス UUID。未確定のうちは `nil`（全件スキャン）。
        public var serviceUUIDs: [UUID]?
        /// 機器名の部分一致フィルタ。AC6000 は `AC6000BT-xxxx` 形式と推定。
        public var nameFilter: String?
        /// 接続後に購読する characteristic。実機の UUID が判明したら埋める。
        public var notifyCharacteristics: [UUID]
        /// 購読完了後に送る初期化コマンド（プロトコル解析で判明したら埋める）。
        public var initialWrites: [(characteristic: UUID, data: Data, withResponse: Bool)]
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
            initialWrites: [(characteristic: UUID, data: Data, withResponse: Bool)] = [],
            autoReconnect: Bool = true,
            reconnectBaseDelay: TimeInterval = 1.0,
            reconnectMaxDelay: TimeInterval = 30.0,
            maxReconnectAttempts: Int? = nil
        ) {
            self.serviceUUIDs = serviceUUIDs
            self.nameFilter = nameFilter
            self.notifyCharacteristics = notifyCharacteristics
            self.initialWrites = initialWrites
            self.autoReconnect = autoReconnect
            self.reconnectBaseDelay = reconnectBaseDelay
            self.reconnectMaxDelay = reconnectMaxDelay
            self.maxReconnectAttempts = maxReconnectAttempts
        }
    }

    /// 「最後に繋いだ機器」を覚えるためのキー。
    public static let lastPeripheralKey = "acechrono.lastPeripheralIdentifier"

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
    public private(set) var discovered = [DiscoveredPeripheral]()
    public private(set) var connectedPeripheral: UUID?

    public nonisolated let events: AsyncStream<ChronoEvent>
    private nonisolated let continuation: AsyncStream<ChronoEvent>.Continuation

    private var pumpTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    /// ユーザーが明示的に切ったのか、勝手に切れたのかを区別する（前者では再接続しない）。
    private var stoppedIntentionally = false

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
    public func forgetDevice() {
        store.set(nil as String?, forKey: Self.lastPeripheralKey)
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
        reconnectTask?.cancel()
        reconnectTask = nil
        await transport.stopScan()
        await transport.disconnect()
        state = .idle
    }

    /// 完全に終了する。イベントストリームも閉じる。
    public func shutdown() async {
        stoppedIntentionally = true
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
        discovered.removeAll()
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
            if !discovered.contains(where: { $0.id == peripheral.id }) {
                discovered.append(peripheral)
            }
            await autoConnectIfAppropriate(to: peripheral)

        case .connected(let peripheral):
            connectedPeripheral = peripheral
            reconnectAttempt = 0
            store.set(peripheral, forKey: Self.lastPeripheralKey)
            await transport.stopScan()
            await subscribeAndInitialize()

        case .disconnected(_, let reason):
            connectedPeripheral = nil
            state = .disconnected(reason: reason)
            scheduleReconnectIfNeeded()

        case .subscribed:
            break

        case .value(let characteristic, let data):
            for decoded in decoder.decode(characteristic: characteristic, data: data) {
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
            await transport.finishSetup()
            state = .ready
        } catch {
            state = .disconnected(reason: "購読に失敗しました: \(error)")
            scheduleReconnectIfNeeded()
        }
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
