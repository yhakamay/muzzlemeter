import Foundation

/// 記録済みパケットを時間軸どおりに流す `ChronoTransport`。
///
/// 用途:
/// - **シミュレータ / SwiftUI Preview**: 実機が無くても Live 画面を作り込める
/// - **テスト**: `speed = 0` にすると一切待たずに全パケットを順番どおり流すので、
///   タイミングに依存しない決定的なテストが書ける
///
/// 再生は「最初の `subscribe(to:)`」で始まる。実機の流れ（scan → connect → subscribe →
/// 受信開始）と同じ順序にすることで、`ChronoDevice` 側のコードをトランスポートの
/// 実装で分岐させずに済む。購読していない characteristic のエントリは捨てる。
public actor ReplayTransport: ChronoTransport {
    /// 書き込みの記録（テストで初期化コマンドの送信を検証するため）。
    public struct RecordedWrite: Sendable, Hashable {
        public let characteristic: UUID
        public let data: Data
        public let withResponse: Bool
    }

    private let script: ReplayScript
    /// 再生速度。1.0 で実時間、2.0 で 2 倍速。**0 なら一切待たない**。
    private let speed: Double
    private let peripheral: DiscoveredPeripheral
    /// 末尾まで再生したら先頭から繰り返すか（デモ用）。`speed == 0` のときは無視される。
    private let repeats: Bool
    private let loopGap: TimeInterval

    public nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation

    private var subscribedCharacteristics = Set<UUID>()
    private var replayTask: Task<Void, Never>?
    private var connected = false
    public private(set) var writes = [RecordedWrite]()

    public init(
        script: ReplayScript,
        speed: Double = 1.0,
        peripheral: DiscoveredPeripheral = ReplayTransport.demoPeripheral,
        repeats: Bool = false,
        loopGap: TimeInterval = 2.0
    ) {
        self.script = script
        self.speed = max(0, speed)
        self.peripheral = peripheral
        self.repeats = repeats
        self.loopGap = loopGap
        let (stream, continuation) = AsyncStream<TransportEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.events = stream
        self.continuation = continuation
    }

    public static let demoPeripheral = DiscoveredPeripheral(
        id: UUID(uuidString: "00000000-0000-0000-0000-ACEC40000000") ?? UUID(),
        name: "AC6000BT-DEMO",
        rssi: -52,
        advertisedServices: []
    )

    // MARK: - ChronoTransport

    public func scan(services: [UUID]?, nameFilter: String?) async throws {
        // 名前フィルタがあるときだけ照合する。サービスフィルタは再生では意味が無いので無視。
        if let nameFilter, !nameFilter.isEmpty {
            let name = peripheral.name?.lowercased() ?? ""
            guard name.contains(nameFilter.lowercased()) else { return }
        }
        continuation.yield(.discovered(peripheral))
    }

    public func stopScan() async {}

    public func connect(to peripheralID: UUID) async throws {
        guard peripheralID == peripheral.id else {
            throw ChronoTransportError.unavailable("未知の peripheral: \(peripheralID)")
        }
        connected = true
        continuation.yield(.connected(peripheral: peripheral.id))
    }

    public func disconnect() async {
        guard connected else { return }
        connected = false
        replayTask?.cancel()
        replayTask = nil
        subscribedCharacteristics.removeAll()
        continuation.yield(.disconnected(peripheral: peripheral.id, reason: nil))
    }

    public func subscribe(to characteristic: UUID) async throws {
        guard connected else { throw ChronoTransportError.notConnected }
        subscribedCharacteristics.insert(characteristic)
        continuation.yield(.subscribed(characteristic: characteristic))
    }

    /// 購読が出揃ってから再生を始める。`ChronoDevice` が購読・初期化書き込みの後に呼ぶ。
    public func finishSetup() async {
        startReplayIfNeeded()
    }

    public func write(_ data: Data, to characteristic: UUID, withResponse: Bool) async throws {
        guard connected else { throw ChronoTransportError.notConnected }
        writes.append(RecordedWrite(characteristic: characteristic, data: data, withResponse: withResponse))
    }

    public func shutdown() async {
        replayTask?.cancel()
        replayTask = nil
        connected = false
        continuation.finish()
    }

    // MARK: - 再生

    private func startReplayIfNeeded() {
        guard replayTask == nil else { return }
        replayTask = Task { [weak self] in
            await self?.runReplay()
        }
    }

    private func runReplay() async {
        // speed == 0（テスト）では無限ループを避けるため repeats を無効にする。
        let shouldRepeat = repeats && speed > 0
        repeat {
            var previousOffset: TimeInterval = 0
            for entry in script.entries {
                if Task.isCancelled { return }
                if speed > 0 {
                    let wait = (entry.offsetSeconds - previousOffset) / speed
                    if wait > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    }
                } else {
                    // 待たない場合でも協調的にスケジューリングの機会を与える。
                    await Task.yield()
                }
                previousOffset = entry.offsetSeconds
                if Task.isCancelled { return }
                guard connected else { return }
                guard subscribedCharacteristics.contains(entry.characteristic) else { continue }
                continuation.yield(.value(characteristic: entry.characteristic, data: entry.data))
            }
            if shouldRepeat {
                try? await Task.sleep(nanoseconds: UInt64(max(0, loopGap / speed) * 1_000_000_000))
            }
        } while shouldRepeat && !Task.isCancelled
    }
}
