import Foundation
import Testing
@testable import MuzzlemeterKit

/// 本体内ログの読み出し（`0x62` / `0x63`）。
///
/// **実機確定の形式**（`docs/PROTOCOL.md` §6.5 / §6.6, 2026-09-03/04 実機追試）。
/// フィクスチャは `tools/re/captures/20260904-000619.log` / `20260904-000817.log` で
/// 実際に採取したフレームをそのまま使う。
@Suite("本体内ログ")
struct DeviceLogTests {
    private static let keys = DeviceKeys(key1: 0xC4, key2: 0x94)

    // MARK: - 実機キャプチャのフィクスチャ（生のバイト列）

    /// `tools/re/captures/20260904-000619.log`。手投げ BB 3 発を撃った直後の状態:
    /// LOG_COUNT が 3 件を報告し、index 1..3 に実データ、index 4..6 は全ゼロ。
    private enum Capture20260904_000619 {
        static let logCountRequest: [UInt8] = [0xAA, 0x05, 0x62, 0x00, 0x69]
        static let logCountResponse: [UInt8] = [0xAA, 0x06, 0x62, 0x03, 0x01, 0x6E]
        /// index 1: rev=0, speed=0x0181=385 → 3.85 m/s
        static let record1: [UInt8] = [0xAA, 0x09, 0x63, 0x01, 0x00, 0x00, 0x81, 0x01, 0xF1]
        /// index 2: rev=0, speed=0x0167=359 → 3.59 m/s
        static let record2: [UInt8] = [0xAA, 0x09, 0x63, 0x02, 0x00, 0x00, 0x67, 0x01, 0xD8]
        /// index 3: rev=0, speed=0x0197=407 → 4.07 m/s
        static let record3: [UInt8] = [0xAA, 0x09, 0x63, 0x03, 0x00, 0x00, 0x97, 0x01, 0x09]
        /// index 4: 全ゼロ（count=3 を超えている）
        static let record4Empty: [UInt8] = [0xAA, 0x09, 0x63, 0x04, 0x00, 0x00, 0x00, 0x00, 0x72]
    }

    /// `tools/re/captures/20260904-000817.log`。電源サイクル直後（ログは volatile なので 0 件）。
    private enum Capture20260904_000817 {
        static let logCountResponse: [UInt8] = [0xAA, 0x06, 0x62, 0x00, 0x01, 0x6B]
        static let record1Empty: [UInt8] = [0xAA, 0x09, 0x63, 0x01, 0x00, 0x00, 0x00, 0x00, 0x6F]
    }

    /// `tools/re/captures/20260903-222919.log`。未知コマンド（0x50）への NAK。
    private static let nakResponse: [UInt8] = [0xAA, 0x05, 0x4E, 0xFF, 0x54]

    // MARK: - フレーム検証（実測との突き合わせ）

    @Test("LOG_COUNT の要求フレームは実機キャプチャと一致する")
    func logCountRequestFrame() {
        let bytes = [UInt8](ChronoCommand.readLogCount(keys: Self.keys))
        #expect(bytes == Capture20260904_000619.logCountRequest)
    }

    @Test("READ_LOG_RECORD は aa 05 63 <index> <cks>（1 byte・1 始まり、実機確定）")
    func readLogRecordFrame() {
        let one = [UInt8](ChronoCommand.readLogRecord(1, keys: Self.keys))
        #expect(one == [0xAA, 0x05, 0x63, 0x01, 0x6B])

        // チェックサムは他のフレームと同じ式（鍵を足す）。
        let expected = ChronoFrame.checksum(one.dropLast(), keys: Self.keys)
        #expect(one.last == expected)
    }

    @Test("CLEAR_LOG(0x61) のビルダは存在しない")
    func noClearLogBuilder() {
        // opcode 一覧にも入れていない（誤って送りようがない状態を保つ）。
        #expect(ChronoCommand(rawValue: 0x61) == nil)
        #expect(!ChronoCommand.allCases.contains { $0.rawValue == 0x61 })
    }

    // MARK: - デコーダ（実機キャプチャのフレームをそのまま流す）

    private func decoder() -> MuzzlemeterDecoder {
        MuzzlemeterDecoder(keys: Self.keys, policy: .strict)
    }

    @Test("LOG_COUNT は payload[0] を件数として読む（旧実装は payload[1] を読んで誤っていた）")
    func decodesLogCount() {
        let events = decoder().decode(
            characteristic: ChronoUUIDs.notifyCharacteristic,
            data: Data(Capture20260904_000619.logCountResponse)
        )
        #expect(events == [.logCount(3)])

        // 電源サイクル直後（ログが空）のキャプチャでは count = 0。
        let emptyEvents = decoder().decode(
            characteristic: ChronoUUIDs.notifyCharacteristic,
            data: Data(Capture20260904_000817.logCountResponse)
        )
        #expect(emptyEvents == [.logCount(0)])
    }

    @Test("実機の 0x63 応答は raw と 1 発の両方が流れ、速度は raw ÷ 100 m/s")
    func decodesRealCaptureLogRecords() {
        let cases: [(bytes: [UInt8], index: Int, mps: Double)] = [
            (Capture20260904_000619.record1, 1, 3.85),
            (Capture20260904_000619.record2, 2, 3.59),
            (Capture20260904_000619.record3, 3, 4.07),
        ]
        for testCase in cases {
            let decoder = self.decoder()
            let events = decoder.decode(
                characteristic: ChronoUUIDs.notifyCharacteristic,
                data: Data(testCase.bytes)
            )
            #expect(events.count == 2)
            guard case .logRecordRaw(let rawIndex, let payload) = events[0] else {
                Issue.record("最初は必ず生 payload"); continue
            }
            #expect(rawIndex == testCase.index)
            #expect(payload.count == 5)

            guard case .logRecord(let index, let shot) = events[1] else {
                Issue.record("読めたら 1 発として続けて流す"); continue
            }
            #expect(index == testCase.index)
            #expect(abs(shot.velocityMetersPerSecond - testCase.mps) < 1e-9)
            #expect(shot.rawRateOfFire == 0)
        }
    }

    @Test("全ゼロの 0x63 応答は「ログの終端」として流れる（エラーではない）")
    func decodesEmptyRecordAsEndOfLog() {
        let decoder = self.decoder()
        let events = decoder.decode(
            characteristic: ChronoUUIDs.notifyCharacteristic,
            data: Data(Capture20260904_000619.record4Empty)
        )
        #expect(events.count == 2)
        guard case .logRecordRaw(let rawIndex, _) = events[0] else {
            Issue.record("最初は必ず生 payload"); return
        }
        #expect(rawIndex == 4)
        guard case .logRecordEmpty(let index) = events[1] else {
            Issue.record("全ゼロは logRecordEmpty として流れる"); return
        }
        #expect(index == 4)
    }

    @Test("電源サイクル直後のキャプチャも全ゼロ = 終端として読める")
    func decodesPowerCycledCaptureAsEmpty() {
        let decoder = self.decoder()
        let events = decoder.decode(
            characteristic: ChronoUUIDs.notifyCharacteristic,
            data: Data(Capture20260904_000817.record1Empty)
        )
        guard case .logRecordEmpty(let index) = events.last else {
            Issue.record("全ゼロは logRecordEmpty として流れる"); return
        }
        #expect(index == 1)
    }

    @Test("NAK（0x4E）は .nak として流れる")
    func decodesNak() {
        let events = decoder().decode(
            characteristic: ChronoUUIDs.notifyCharacteristic,
            data: Data(Self.nakResponse)
        )
        #expect(events == [.nak])
    }

    // MARK: - 読み出しループ（擬似ファームウェア）

    /// 記録済みパケットではなく**要求に応答する**擬似本体。
    /// 鍵ハンドシェイク（`0x4B` → ACK）とログ読み出しの両方に答える。
    private static func firmware(count: Int, brokenIndex: Int? = nil) -> ReplayTransport.Responder {
        let log = ReplayTransport.deviceLogResponder(
            count: count,
            keys: keys,
            brokenIndex: brokenIndex,
            speeds: [88.4, 89.1, 90.6]
        )
        return { request in
            let bytes = [UInt8](request)
            if bytes.count >= 3, bytes[2] == ChronoCommand.readKey.rawValue {
                return [
                    ChronoFrame(command: .ack, payload: [ChronoCommand.readKey.rawValue])
                        .encode(keys: keys)
                ]
            }
            return log(request)
        }
    }

    private func makeReadyDevice(
        count: Int,
        brokenIndex: Int? = nil,
        responder: ReplayTransport.Responder? = nil
    ) async -> ChronoDevice {
        let transport = ReplayTransport(
            script: ReplayScript(entries: []),
            speed: 0,
            responder: responder ?? Self.firmware(count: count, brokenIndex: brokenIndex),
            responseDelay: 0.01
        )
        let device = ChronoDevice(
            transport: transport,
            decoder: MuzzlemeterDecoder(),
            configuration: .ac6000(
                autoReconnect: false,
                handshake: .init(
                    initialDelay: 0,
                    ackTimeout: 2,
                    retryCount: 0,
                    commandGap: 0,
                    readsCurrentAmmo: false
                )
            )
        )
        let events = device.events
        await device.start()
        for await event in events {
            if case .connectionState(.ready) = event { break }
        }
        return device
    }

    private var options: DeviceLogReadOptions {
        DeviceLogReadOptions(responseTimeout: 2, commandGap: 0)
    }

    @Test("件数 3 → index 1..3 を読み切る")
    func readsAllRecords() async {
        let device = await makeReadyDevice(count: 3)
        let recorder = ProgressRecorder()
        let result = await device.readDeviceLog(options: options) { recorder.append($0) }
        let progress = recorder.values

        #expect(result.reportedCount == 3)
        #expect(result.outcome == .completed)
        #expect(result.records.count == 3)
        #expect(result.shots.count == 3)
        // index は 1 始まり（実機確定）。
        #expect(result.records.map(\.index) == [1, 2, 3])
        #expect(abs(result.shots[0].velocityMetersPerSecond - 88.4) < 1e-9)
        #expect(abs(result.shots[2].velocityMetersPerSecond - 90.6) < 1e-9)
        #expect(progress.map(\.done) == [1, 2, 3])
        #expect(progress.allSatisfy { $0.total == 3 })
        #expect(result.lastReadIndex == 3)
        await device.shutdown()
    }

    @Test("startIndex を進めれば差分だけ読める（volatile ログの再取り込み対策）")
    func readsOnlyTheDelta() async {
        let device = await makeReadyDevice(count: 5)
        let result = await device.readDeviceLog(
            options: DeviceLogReadOptions(responseTimeout: 2, commandGap: 0, startIndex: 4)
        )
        #expect(result.reportedCount == 5)
        #expect(result.outcome == .completed)
        #expect(result.records.map(\.index) == [4, 5])
        await device.shutdown()
    }

    @Test("startIndex が件数を超えていれば何も読まない")
    func startIndexBeyondCountReadsNothing() async {
        let device = await makeReadyDevice(count: 3)
        let result = await device.readDeviceLog(
            options: DeviceLogReadOptions(responseTimeout: 2, commandGap: 0, startIndex: 4)
        )
        #expect(result.reportedCount == 3)
        #expect(result.outcome == .completed)
        #expect(result.records.isEmpty)
        await device.shutdown()
    }

    @Test("読めないレコードで止まり、そこまでは残る（未知のファームウェア差異への保険）")
    func stopsOnUnparseableRecord() async {
        let device = await makeReadyDevice(count: 3, brokenIndex: 2)
        let result = await device.readDeviceLog(options: options)

        #expect(result.outcome == .unsupportedFormat(index: 2))
        // 読めなかった 1 件も**捨てずに**返る（生データを書き出して送り返してもらうため）。
        #expect(result.records.count == 2)
        #expect(result.shots.count == 1)
        #expect(result.records.last?.isParsed == false)
        await device.shutdown()
    }

    @Test("0 件なら何も要求しない")
    func emptyLogRequestsNothing() async {
        let device = await makeReadyDevice(count: 0)
        let result = await device.readDeviceLog(options: options)
        #expect(result.outcome == .completed)
        #expect(result.records.isEmpty)
        await device.shutdown()
    }

    @Test("0x63 に応答が無ければタイムアウトで止まる")
    func timesOutWhenRecordIsUnanswered() async {
        // 件数だけ答えてレコードには答えない本体（＝ 0x63 に応答が無い異常系）。
        let responder: ReplayTransport.Responder = { request in
            let bytes = [UInt8](request)
            if bytes.count >= 3, bytes[2] == ChronoCommand.readKey.rawValue {
                return [
                    ChronoFrame(command: .ack, payload: [ChronoCommand.readKey.rawValue])
                        .encode(keys: Self.keys)
                ]
            }
            if bytes.count >= 3, bytes[2] == ChronoCommand.logCount.rawValue {
                return [
                    ChronoFrame(command: .logCount, payload: [0x02, 0x01]).encode(keys: Self.keys)
                ]
            }
            return []
        }
        let device = await makeReadyDevice(count: 2, responder: responder)
        let result = await device.readDeviceLog(
            options: DeviceLogReadOptions(responseTimeout: 0.2, commandGap: 0)
        )
        #expect(result.reportedCount == 2)
        #expect(result.outcome == .timedOut(index: 1))
        #expect(result.records.isEmpty)
        await device.shutdown()
    }

    @Test("readLogCount は件数だけを best-effort で返す")
    func readsLogCountOnly() async {
        let device = await makeReadyDevice(count: 5)
        let count = await device.readLogCount(timeout: 2)
        #expect(count == 5)
        await device.shutdown()
    }
}

/// 進捗コールバックは別スレッドから呼ばれるので、まとめて受け取る箱を挟む。
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [DeviceLogProgress]()

    func append(_ value: DeviceLogProgress) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }

    var values: [DeviceLogProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
