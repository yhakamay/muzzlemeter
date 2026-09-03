import Foundation
import Testing
@testable import ShotLogKit

@Suite("ShotLogDecoder")
struct ShotLogDecoderTests {
    private let characteristic = ChronoUUIDs.notifyCharacteristic
    private let keys = Fixtures.keys

    private func makeDecoder() -> ShotLogDecoder {
        ShotLogDecoder(keys: keys)
    }

    @Test("FIRE_REPORT 5 発が既知の rawSpeed / 速度になる")
    func fireReports() throws {
        let decoder = makeDecoder()
        var shots = [Shot]()
        for data in try Fixtures.rx() {
            for event in decoder.decode(characteristic: characteristic, data: data) {
                if case .shot(let shot) = event { shots.append(shot) }
            }
        }
        #expect(shots.count == 5)
        // rawSpeed 282 / 250 / 267 / 266 / 305、速度は ÷100（実機 LCD で確定）。
        let expected: [Double] = [2.82, 2.50, 2.67, 2.66, 3.05]
        for (shot, value) in zip(shots, expected) {
            #expect(abs(shot.velocityMetersPerSecond - value) < 1e-9)
        }
        // 単発なので rawRev は 0。単位が未確定なので rateOfFireRPS は埋めない。
        #expect(shots.allSatisfy { $0.rawRateOfFire == 0 })
        #expect(shots.allSatisfy { $0.rateOfFireRPS == nil })
    }

    @Test("FireReport は生値を保持し、速度スケールは 1 箇所に閉じている")
    func fireReportRawValues() throws {
        let report = try #require(FireReport(payload: [0x00, 0x00, 0x1A, 0x01, 0x00, 0x00]))
        #expect(report.rawSpeed == 282)
        #expect(report.rawRev == 0)
        #expect(report.flags == 0)
        #expect(abs(report.metersPerSecond - 2.82) < 1e-9)
        #expect(FireReport.speedScale == 100.0)
    }

    @Test("キャプチャ全体を通すと ack / ammo / logCount / shot / powerOff に分類される")
    func classifiesWholeCapture() throws {
        let decoder = makeDecoder()
        var acks = [UInt8]()
        var ammo = [AmmoRecord]()
        var logCounts = [Int]()
        var shots = 0
        var powerOffs = 0
        var raws = 0

        for data in try Fixtures.rx() {
            for event in decoder.decode(characteristic: characteristic, data: data) {
                switch event {
                case .ack(let command): acks.append(command)
                case .ammo(let record): ammo.append(record)
                case .logCount(let count): logCounts.append(count)
                case .shot: shots += 1
                case .powerOff: powerOffs += 1
                case .raw: raws += 1
                default: break
                }
            }
        }

        #expect(acks == [ChronoCommand.readKey.rawValue])
        #expect(shots == 5)
        #expect(logCounts == [1])
        #expect(powerOffs == 1)
        #expect(raws == 0)

        // 0x5A が 2 本（現在の弾）、0x47 が 6 本（プリセット 1..5 + 自発再送の 1）。
        #expect(ammo.count == 8)
        #expect(ammo.filter(\.isCurrent).count == 2)
        let preset1 = try #require(ammo.first { !$0.isCurrent })
        #expect(preset1.slot == 1)
        #expect(preset1.rawDiameter == 600)
        #expect(preset1.rawWeight == 20)
        #expect(abs(preset1.diameterMm - 6.0) < 1e-9)
        #expect(abs((preset1.weightGrams ?? 0) - 0.20) < 1e-9)
        #expect(preset1.marker == 0x41)
    }

    @Test("要求していない 0x47（marker 0x40）も正常なフレームとして読む")
    func unsolicitedAmmoPreset() {
        // 実機で ACK の 10 秒後に自発的に飛んできたフレーム。
        // marker が 0x40（キャプチャは 0x41）、重量が 0x00c8 = 200 と異なるが、
        // チェックサムは鍵 c4/94 で正しい。raw を保ったまま受け取れること。
        let data = Data([0xAA, 0x0B, 0x47, 0x00, 0x40, 0x01, 0x58, 0x02, 0xC8, 0x00, 0xB7])
        #expect(ChronoFrame.decode(data, keys: keys, acceptUnkeyedChecksum: false).failure == nil)

        let decoder = makeDecoder()
        let events = decoder.decode(characteristic: characteristic, data: data)
        #expect(events.count == 1)
        guard case .ammo(let record) = events[0] else {
            Issue.record("ammo として解釈されていない: \(events)")
            return
        }
        #expect(record.slot == 1)
        #expect(record.marker == 0x40)
        #expect(record.rawWeight == 200)
        #expect(record.rawDiameter == 600)
        #expect(!record.isCurrent)
        // 200 は ×1000 で 0.20 g と読む（×100 の 2.00 g は実在しない）。
        #expect(abs((record.weightGrams ?? 0) - 0.20) < 1e-9)
        #expect(record.marker == AmmoRecord.spontaneousMarker)
    }

    @Test("未知 cmd とチェックサム不一致は .raw として流し、例外にしない")
    func unknownAndBrokenFramesBecomeRaw() {
        let decoder = makeDecoder()
        // 未知 cmd 0x99（チェックサムは正しい）。
        let unknown = ChronoFrame(cmd: 0x99, payload: [0x01]).encode(keys: keys)
        guard case .raw(_, let raw) = decoder.decode(characteristic: characteristic, data: unknown).first else {
            Issue.record("未知 cmd が .raw になっていない")
            return
        }
        #expect(raw == unknown)

        // チェックサムを壊した FIRE_REPORT。鍵が確定しているので .raw に落ちる。
        var broken = Data([0xAA, 0x0A, 0x52, 0x00, 0x00, 0x1A, 0x01, 0x00, 0x00, 0x79])
        broken[9] = 0x00
        let events = decoder.decode(characteristic: characteristic, data: broken)
        #expect(events.count == 1)
        if case .raw = events[0] {} else { Issue.record("壊れたフレームが .raw になっていない") }
    }

    @Test("鍵が未確定のうちはチェックサムを検証せず読み進める（初回ペアリング用）")
    func lenientUntilKeysKnown() {
        let decoder = ShotLogDecoder()   // keys = 0/0
        let data = Data([0xAA, 0x0A, 0x52, 0x00, 0x00, 0x1A, 0x01, 0x00, 0x00, 0x79])
        guard case .shot(let shot) = decoder.decode(characteristic: characteristic, data: data).first else {
            Issue.record("鍵未確定時にフレームを読めていない")
            return
        }
        #expect(abs(shot.velocityMetersPerSecond - 2.82) < 1e-9)

        // 鍵を確定させたら、合わないフレームは .raw に落ちる。
        decoder.updateKeys(DeviceKeys(key1: 0x11, key2: 0x22))
        if case .raw = decoder.decode(characteristic: characteristic, data: data).first {} else {
            Issue.record("鍵確定後もチェックサムを検証していない")
        }
    }

    @Test("strict では鍵未確定でも検証する")
    func strictPolicy() {
        let decoder = ShotLogDecoder(policy: .strict)
        let data = Data([0xAA, 0x0A, 0x52, 0x00, 0x00, 0x1A, 0x01, 0x00, 0x00, 0x79])
        if case .raw = decoder.decode(characteristic: characteristic, data: data).first {} else {
            Issue.record("strict なのに検証していない")
        }
    }

    @Test("2 本連結された通知も 2 イベントに分かれる")
    func handlesConcatenatedNotification() {
        let decoder = makeDecoder()
        let ack = Data([0xAA, 0x05, 0x41, 0x4B, 0x93])
        let fire = Data([0xAA, 0x0A, 0x52, 0x00, 0x00, 0x1A, 0x01, 0x00, 0x00, 0x79])
        let events = decoder.decode(characteristic: characteristic, data: ack + fire)
        #expect(events.count == 2)
        if case .ack(let command) = events[0] { #expect(command == 0x4B) } else { Issue.record("ack が無い") }
        if case .shot = events[1] {} else { Issue.record("shot が無い") }
    }

    @Test("1 バイトの 00 は .powerOff になる")
    func powerOff() {
        let decoder = makeDecoder()
        let events = decoder.decode(characteristic: characteristic, data: Data([0x00]))
        #expect(events.count == 1)
        if case .powerOff = events[0] {} else { Issue.record("powerOff ではない") }
    }
}
