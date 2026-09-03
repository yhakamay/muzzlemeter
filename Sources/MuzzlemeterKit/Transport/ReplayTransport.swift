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

    /// 書き込まれたフレームに**その場で応答する**擬似ファームウェア。
    ///
    /// 記録済みパケットの再生だけでは「要求 → 応答」の往復（`0x62` / `0x63` の
    /// ログ読み出しなど）を通せない。要求 1 本に対して返すフレームを組み立てる
    /// 関数を差し込めるようにして、**アプリ側は実機と同じ経路**（write → notify）を
    /// 通れるようにする。応答が無い要求には空配列を返す。
    public typealias Responder = @Sendable (Data) -> [Data]

    private let script: ReplayScript
    /// 再生速度。1.0 で実時間、2.0 で 2 倍速。**0 なら一切待たない**。
    private let speed: Double
    private let peripheral: DiscoveredPeripheral
    /// 末尾まで再生したら先頭から繰り返すか（デモ用）。`speed == 0` のときは無視される。
    private let repeats: Bool
    private let loopGap: TimeInterval
    private let responder: Responder?
    /// 応答を返すまでの遅れ。実機の応答は 45–63 ms だった（`docs/PROTOCOL.md` §4.2）。
    private let responseDelay: TimeInterval
    /// 応答を流す characteristic（実機と同じ notify 側）。
    private let responseCharacteristic: UUID

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
        loopGap: TimeInterval = 2.0,
        responder: Responder? = nil,
        responseDelay: TimeInterval = 0.05,
        responseCharacteristic: UUID = ChronoUUIDs.notifyCharacteristic
    ) {
        self.script = script
        self.speed = max(0, speed)
        self.peripheral = peripheral
        self.repeats = repeats
        self.loopGap = loopGap
        self.responder = responder
        self.responseDelay = max(0, responseDelay)
        self.responseCharacteristic = responseCharacteristic
        let (stream, continuation) = AsyncStream<TransportEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.events = stream
        self.continuation = continuation
    }

    /// 再生用の擬似ペリフェラル。
    ///
    /// manufacturer data には**実機の広告そのまま**（`00 05 08 c4 94 52 04`）を載せてある。
    /// こうしておくと `ChronoDevice` が実機と同じ経路で鍵 `c4/94` を取り出せるので、
    /// 記録済みフレームのチェックサム検証まで含めて本番と同じコードが走る。
    public static let demoPeripheral = DiscoveredPeripheral(
        id: UUID(uuidString: "00000000-0000-0000-0000-ACEC40000000") ?? UUID(),
        name: "AC6000BT-DEMO",
        rssi: -52,
        advertisedServices: [],
        manufacturerData: Data([0x00, 0x05, 0x08, 0xC4, 0x94, 0x52, 0x04])
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
        respond(to: data)
    }

    /// 擬似ファームウェアの応答を流す。
    ///
    /// **別タスクで流す**のが要点。`write` の呼び出し元は応答を待っているので、
    /// ここで直接 yield しても構わないが、実機の「少し遅れて notify が来る」順序に
    /// 合わせておくと、待ち始める前に応答が来る取りこぼしを実装側で踏める。
    private func respond(to request: Data) {
        guard let responder else { return }
        let responses = responder(request)
        guard !responses.isEmpty else { return }
        guard subscribedCharacteristics.contains(responseCharacteristic) else { return }
        let characteristic = responseCharacteristic
        let delay = responseDelay
        Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await self?.emit(responses, on: characteristic)
        }
    }

    private func emit(_ responses: [Data], on characteristic: UUID) {
        guard connected else { return }
        for response in responses {
            continuation.yield(.value(characteristic: characteristic, data: response))
        }
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

// MARK: - 擬似ファームウェア

extension ReplayTransport {
    /// 本体内ログの読み出し（`0x62` / `0x63`）に応答する擬似ファームウェア。
    ///
    /// **`0x63` の実物は 1 度も観測できていない**（`docs/PROTOCOL.md` §6.6）。
    /// ここが返すのは「`FIRE_REPORT` と同じ並びだろう」という**推定に基づく作りもの**で、
    /// 実機の形式が判明したら差し替える。にもかかわらずこれを用意するのは、
    /// アプリ側の取り込み UI（進捗・保存・失敗時の生データ書き出し）を
    /// 実機なしで通しで動かすため。
    ///
    /// - Parameters:
    ///   - count: `0x62` が答える件数。
    ///   - brokenIndex: この番号のレコードだけ**読めない形**で返す。
    ///     「未対応の形式でした」の経路を実機なしで確かめるために要る。
    ///   - speeds: レコードの速度（m/s）。足りなければ巡回して使う。
    public static func deviceLogResponder(
        count: Int,
        keys: DeviceKeys = DeviceKeys(key1: 0xC4, key2: 0x94),
        brokenIndex: Int? = nil,
        speeds: [Double] = [88.4, 89.1, 90.6, 91.3, 87.9, 92.2, 90.0, 88.8]
    ) -> Responder {
        { request in
            let bytes = [UInt8](request)
            guard bytes.count >= 4, bytes[0] == ChronoFrame.header else { return [] }
            switch bytes[2] {
            case ChronoCommand.logCount.rawValue:
                // aa 06 62 <status> <count> cks（§6.5 の読み方に合わせる）
                return [
                    ChronoFrame(command: .logCount, payload: [0x00, UInt8(clamping: count)])
                        .encode(keys: keys)
                ]

            case ChronoCommand.logRecord.rawValue:
                guard bytes.count >= 5 else { return [] }
                let index = Int(bytes[3]) | (Int(bytes[4]) << 8)
                guard index < count else { return [] }
                if index == brokenIndex {
                    // 長さも並びも FIRE_REPORT に合わない = 「未対応の形式」。
                    return [ChronoFrame(command: .logRecord, payload: [0x01, 0x02]).encode(keys: keys)]
                }
                let speed = speeds.isEmpty ? 90.0 : speeds[index % speeds.count]
                let raw = UInt16(clamping: Int((speed * FireReport.speedScale).rounded()))
                let payload: [UInt8] = [
                    0x00, 0x00,
                    UInt8(raw & 0xFF), UInt8(raw >> 8),
                    0x00, 0x00,
                ]
                return [ChronoFrame(command: .logRecord, payload: payload).encode(keys: keys)]

            default:
                return []
            }
        }
    }
}
