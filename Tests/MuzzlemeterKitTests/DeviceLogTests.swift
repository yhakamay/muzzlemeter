import Foundation
import Testing
@testable import MuzzlemeterKit

/// 本体内ログの読み出し（`0x62` / `0x63`）。
///
/// **`0x63` は実物を 1 度も観測できていない**（`docs/PROTOCOL.md` §6.6）。
/// ここで確かめているのは「実機がこう答えるはず」ではなく、
/// **推定した形式で答えが返ってきたときにアプリが正しく振る舞うか**と、
/// **推定が外れていたときに黙って壊れないか**の 2 点である。
@Suite("本体内ログ")
struct DeviceLogTests {
    private static let keys = DeviceKeys(key1: 0xC4, key2: 0x94)

    // MARK: - 要求フレーム

    @Test("READ_LOG_RECORD は aa 06 63 <index LE16> <cks>（推定）")
    func readLogRecordFrame() {
        let zero = ChronoCommand.readLogRecord(0, keys: Self.keys)
        #expect([UInt8](zero).prefix(5) == [0xAA, 0x06, 0x63, 0x00, 0x00])

        let big = ChronoCommand.readLogRecord(258, keys: Self.keys)
        #expect([UInt8](big).prefix(5) == [0xAA, 0x06, 0x63, 0x02, 0x01])

        // チェックサムは他のフレームと同じ式（鍵を足す）。
        let bytes = [UInt8](zero)
        let expected = ChronoFrame.checksum(bytes.dropLast(), keys: Self.keys)
        #expect(bytes.last == expected)
    }

    @Test("CLEAR_LOG(0x61) のビルダは存在しない")
    func noClearLogBuilder() {
        // opcode 一覧にも入れていない（誤って送りようがない状態を保つ）。
        #expect(ChronoCommand(rawValue: 0x61) == nil)
        #expect(!ChronoCommand.allCases.contains { $0.rawValue == 0x61 })
    }

    // MARK: - デコーダ

    private func decoder() -> MuzzlemeterDecoder {
        MuzzlemeterDecoder(keys: Self.keys, policy: .strict)
    }

    private func logRecordFrame(speed: Double) -> Data {
        let raw = UInt16((speed * FireReport.speedScale).rounded())
        return ChronoFrame(
            command: .logRecord,
            payload: [0x00, 0x00, UInt8(raw & 0xFF), UInt8(raw >> 8), 0x00, 0x00]
        ).encode(keys: Self.keys)
    }

    @Test("FIRE_REPORT の並びに見える 0x63 は raw と 1 発の両方が流れる")
    func decodesLogRecordAsShot() {
        let decoder = self.decoder()
        decoder.expectLogRecord(index: 2)
        let events = decoder.decode(
            characteristic: ChronoUUIDs.notifyCharacteristic,
            data: logRecordFrame(speed: 91.2)
        )

        #expect(events.count == 2)
        guard case .logRecordRaw(let rawIndex, let payload) = events[0] else {
            Issue.record("最初は必ず生 payload"); return
        }
        #expect(rawIndex == 2)
        #expect(payload == [0x00, 0x00, 0xA0, 0x23, 0x00, 0x00])  // 9120 = 91.20 m/s

        guard case .logRecord(let index, let shot) = events[1] else {
            Issue.record("読めたら 1 発として続けて流す"); return
        }
        #expect(index == 2)
        #expect(abs(shot.velocityMetersPerSecond - 91.2) < 1e-9)
    }

    @Test("読めない 0x63 は生 payload だけが流れる（速度をでっち上げない）")
    func decodesUnparseableLogRecordAsRawOnly() {
        let decoder = self.decoder()
        decoder.expectLogRecord(index: 0)
        let frame = ChronoFrame(command: .logRecord, payload: [0x01, 0x02]).encode(keys: Self.keys)
        let events = decoder.decode(characteristic: ChronoUUIDs.notifyCharacteristic, data: frame)

        #expect(events.count == 1)
        guard case .logRecordRaw(let index, let payload) = events[0] else {
            Issue.record("生 payload は必ず流す"); return
        }
        #expect(index == 0)
        #expect(payload == [0x01, 0x02])
    }

    @Test("index を教えられていなければ nil のまま流す（嘘の番号を付けない）")
    func decodesWithoutIndexHint() {
        let events = decoder().decode(
            characteristic: ChronoUUIDs.notifyCharacteristic,
            data: logRecordFrame(speed: 90.0)
        )
        guard case .logRecordRaw(let index, _) = events.first else {
            Issue.record("生 payload が無い"); return
        }
        #expect(index == nil)
    }

    @Test("flags や速度が 0 のものは 1 発として読まない")
    func rejectsImplausibleLogRecords() {
        // 速度 0
        #expect(FireReport.logRecord(payload: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) == nil)
        // flags が 0 でない（FIRE_REPORT では実測 5 発とも 0 だった）
        #expect(FireReport.logRecord(payload: [0x01, 0x00, 0x90, 0x23, 0x00, 0x00]) == nil)
        // 短すぎる
        #expect(FireReport.logRecord(payload: [0x00, 0x00, 0x90]) == nil)
        // 通るもの
        #expect(FireReport.logRecord(payload: [0x00, 0x00, 0x90, 0x23, 0x00, 0x00])?.rawSpeed == 9104)
    }

    // MARK: - 読み出しループ

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

    @Test("件数 3 → 3 件読み切る")
    func readsAllRecords() async {
        let device = await makeReadyDevice(count: 3)
        let recorder = ProgressRecorder()
        let result = await device.readDeviceLog(options: options) { recorder.append($0) }
        let progress = recorder.values

        #expect(result.reportedCount == 3)
        #expect(result.outcome == .completed)
        #expect(result.records.count == 3)
        #expect(result.shots.count == 3)
        #expect(result.records.map(\.index) == [0, 1, 2])
        #expect(abs(result.shots[0].velocityMetersPerSecond - 88.4) < 1e-9)
        #expect(abs(result.shots[2].velocityMetersPerSecond - 90.6) < 1e-9)
        #expect(progress.map(\.done) == [1, 2, 3])
        #expect(progress.allSatisfy { $0.total == 3 })
        await device.shutdown()
    }

    @Test("読めないレコードで止まり、そこまでは残る")
    func stopsOnUnparseableRecord() async {
        let device = await makeReadyDevice(count: 3, brokenIndex: 1)
        let result = await device.readDeviceLog(options: options)

        #expect(result.outcome == .unsupportedFormat(index: 1))
        // 読めなかった 1 件も**捨てずに**返る（生データを書き出して送り返してもらうため）。
        #expect(result.records.count == 2)
        #expect(result.shots.count == 1)
        #expect(result.records.last?.isParsed == false)
        #expect(result.records.last?.payload == [0x01, 0x02])
        #expect(result.records.last?.hexLine == "1 01 02")
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
        // 件数だけ答えてレコードには答えない本体（＝ 0x63 の推定が外れている場合）。
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
                    ChronoFrame(command: .logCount, payload: [0x00, 0x02]).encode(keys: Self.keys)
                ]
            }
            return []
        }
        let device = await makeReadyDevice(count: 2, responder: responder)
        let result = await device.readDeviceLog(
            options: DeviceLogReadOptions(responseTimeout: 0.2, commandGap: 0)
        )
        #expect(result.reportedCount == 2)
        #expect(result.outcome == .timedOut(index: 0))
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
