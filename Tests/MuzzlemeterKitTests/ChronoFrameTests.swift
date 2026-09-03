import Foundation
import Testing
@testable import MuzzlemeterKit

@Suite("ChronoFrame（フレーム符号化）")
struct ChronoFrameTests {
    private let keys = Fixtures.keys

    // MARK: - 実キャプチャとの突き合わせ

    @Test("TX 8 本すべてが鍵 c4/94 でバイト単位に再構成できる")
    func txFramesRoundTrip() throws {
        let frames = try Fixtures.tx()
        #expect(frames.count == 8)

        for data in frames {
            // READ_KEY だけは鍵確立前なので 0/0 で署名されている。
            let isReadKey = data.count > 2 && data[data.startIndex + 2] == ChronoCommand.readKey.rawValue
            let signingKeys = isReadKey ? DeviceKeys.zero : keys

            let decoded = try ChronoFrame.decode(data, keys: signingKeys, acceptUnkeyedChecksum: false).get()
            #expect(decoded.encode(keys: signingKeys) == data, "再構成が一致しません: \(HexBytes.string(data))")
            #expect(decoded.length == data.count)
        }
    }

    @Test("RX フレームは鍵 c4/94 で全て検証を通る（1 バイトの電源 OFF 通知を除く）")
    func rxFramesValidate() throws {
        let frames = try Fixtures.rx()
        #expect(frames.count == 16)

        let appFrames = frames.filter { $0.count > 1 }
        #expect(appFrames.count == 15)
        for data in appFrames {
            let result = ChronoFrame.decode(data, keys: keys, acceptUnkeyedChecksum: false)
            #expect(
                result.failure == nil,
                "検証に失敗: \(HexBytes.string(data)) -> \(result.failure?.description ?? "")"
            )
        }
        // 最後の 1 本は 1 バイトの 00（フレームではない）。
        #expect(frames.last == Data([0x00]))
    }

    @Test("ドキュメントの計算例どおりのチェックサムになる")
    func checksumWorkedExamples() {
        // aa 06 4b c4 94 -> 0x53（鍵確立前）
        #expect(ChronoFrame.checksum([0xAA, 0x06, 0x4B, 0xC4, 0x94], keys: .zero) == 0x53)
        // aa 05 5a 00 -> 0x61（鍵確立後）
        #expect(ChronoFrame.checksum([0xAA, 0x05, 0x5A, 0x00], keys: keys) == 0x61)
        // FIRE_REPORT
        #expect(
            ChronoFrame.checksum([0xAA, 0x0A, 0x52, 0x00, 0x00, 0x1A, 0x01, 0x00, 0x00], keys: keys) == 0x79
        )
    }

    @Test("鍵を知らないと RX を検証できない（鍵なし総和では不一致）")
    func unkeyedChecksumFailsForKeyedFrames() {
        let frame = Data([0xAA, 0x0A, 0x52, 0x00, 0x00, 0x1A, 0x01, 0x00, 0x00, 0x79])
        let result = ChronoFrame.decode(frame, keys: .zero, acceptUnkeyedChecksum: true)
        #expect((try? result.get()) == nil)
    }

    // MARK: - ビルダ

    @Test("リクエストのビルダがキャプチャの TX と一致する")
    func requestBuildersMatchCapture() throws {
        #expect(ChronoCommand.readKey(keys: keys) == Data([0xAA, 0x06, 0x4B, 0xC4, 0x94, 0x53]))
        #expect(ChronoCommand.readCurrentAmmo(keys: keys) == Data([0xAA, 0x05, 0x5A, 0x00, 0x61]))
        #expect(ChronoCommand.readLogCount(keys: keys) == Data([0xAA, 0x05, 0x62, 0x00, 0x69]))
        #expect(ChronoCommand.readAmmoPreset(1, keys: keys) == Data([0xAA, 0x06, 0x47, 0x01, 0x01, 0x51]))
        #expect(ChronoCommand.readAmmoPreset(5, keys: keys) == Data([0xAA, 0x06, 0x47, 0x01, 0x05, 0x55]))

        // TX フィクスチャの 8 本を順に再現できる。
        let expected = try Fixtures.tx()
        let built: [Data] = [
            ChronoCommand.readKey(keys: keys),
            ChronoCommand.readCurrentAmmo(keys: keys),
            ChronoCommand.readLogCount(keys: keys),
        ] + (1...5).map { ChronoCommand.readAmmoPreset(UInt8($0), keys: keys) }
        #expect(built == expected)
    }

    @Test("READ_KEY は鍵を渡しても 0/0 で署名される")
    func readKeyIsAlwaysSignedWithZeroKeys() {
        #expect(ChronoRequest.readKey(keys).encoded(keys: keys) == ChronoRequest.readKey(keys).frame.encode(keys: .zero))
    }

    @Test("バッテリー要求は aa 05 2c 00 <cks>")
    func batteryRequest() {
        let data = ChronoCommand.readBattery(keys: keys)
        #expect(data.prefix(4) == Data([0xAA, 0x05, 0x2C, 0x00]))
        #expect(data.count == 5)
        #expect((try? ChronoFrame.decode(data, keys: keys, acceptUnkeyedChecksum: false).get()) != nil)
    }

    // MARK: - 異常系

    @Test("ヘッダ・長さ・チェックサムの誤りを検出する")
    func rejectsMalformedFrames() {
        #expect(ChronoFrame.decode(Data(), keys: keys).failure == .empty)
        #expect(ChronoFrame.decode(Data([0x85, 0x05, 0x5A, 0x00, 0x61]), keys: keys).failure == .badHeader(0x85))
        #expect(ChronoFrame.decode(Data([0xAA, 0x06, 0x5A, 0x00, 0x61]), keys: keys).failure
            == .lengthMismatch(declared: 6, actual: 5))
        #expect(ChronoFrame.decode(Data([0xAA, 0x05, 0x5A, 0x00, 0x62]), keys: keys, acceptUnkeyedChecksum: false).failure
            == .checksumMismatch(expected: 0x61, actual: 0x62))
        #expect(ChronoFrame.decode(Data([0xAA, 0x02]), keys: keys).failure == .tooShort(2))
    }
}

@Suite("FrameAssembler（ストリーム分割）")
struct FrameAssemblerTests {
    private let keys = Fixtures.keys
    private let fire = Data([0xAA, 0x0A, 0x52, 0x00, 0x00, 0x1A, 0x01, 0x00, 0x00, 0x79])
    private let ack = Data([0xAA, 0x05, 0x41, 0x4B, 0x93])

    private func makeAssembler() -> FrameAssembler {
        var assembler = FrameAssembler()
        assembler.keys = keys
        return assembler
    }

    @Test("1 通知 = 1 フレーム")
    func singleFrame() {
        var assembler = makeAssembler()
        let out = assembler.append(fire)
        #expect(out.count == 1)
        guard case .frame(let frame, _) = out[0] else { Issue.record("frame ではない"); return }
        #expect(frame.command == .fireReport)
    }

    @Test("連結された 2 フレームを長さで切り分ける")
    func concatenatedFrames() {
        var assembler = makeAssembler()
        let out = assembler.append(ack + fire)
        #expect(out.count == 2)
        guard case .frame(let first, _) = out[0], case .frame(let second, _) = out[1] else {
            Issue.record("2 本に切り出せていない")
            return
        }
        #expect(first.command == .ack)
        #expect(second.command == .fireReport)
        #expect(assembler.bufferedByteCount == 0)
    }

    @Test("分割されたフレームは揃うまで待つ")
    func splitFrame() {
        var assembler = makeAssembler()
        #expect(assembler.append(fire.prefix(3)).isEmpty)
        #expect(assembler.append(fire.dropFirst(3).prefix(4)).isEmpty)
        let out = assembler.append(fire.dropFirst(7))
        #expect(out.count == 1)
        if case .frame(let frame, let raw) = out[0] {
            #expect(frame.command == .fireReport)
            #expect(raw == fire)
        } else {
            Issue.record("frame ではない")
        }
    }

    @Test("1 バイトずつ届いても組み立てられる")
    func bytewiseDelivery() {
        var assembler = makeAssembler()
        var outputs = [FrameAssembler.Output]()
        for byte in ack {
            outputs.append(contentsOf: assembler.append(Data([byte])))
        }
        #expect(outputs.count == 1)
    }

    @Test("1 バイトの 00 は電源 OFF として扱う（エラーにしない）")
    func powerOffNotification() {
        var assembler = makeAssembler()
        let out = assembler.append(Data([0x00]))
        #expect(out == [.powerOff])
    }

    @Test("先頭のごみは読み飛ばして同期を取り直す")
    func resynchronizesAfterGarbage() {
        var assembler = makeAssembler()
        let out = assembler.append(Data([0x11, 0x22]) + fire)
        #expect(out.count == 2)
        if case .invalid(let raw, _) = out[0] {
            #expect(raw == Data([0x11, 0x22]))
        } else {
            Issue.record("先頭のごみが invalid になっていない")
        }
        if case .frame(let frame, _) = out[1] {
            #expect(frame.command == .fireReport)
        } else {
            Issue.record("後続フレームを取り出せていない")
        }
    }

    @Test("チェックサム不一致は invalid として返る（例外にしない）")
    func checksumMismatchIsReported() {
        var assembler = makeAssembler()
        var broken = fire
        broken[broken.count - 1] = 0x00
        let out = assembler.append(broken)
        #expect(out.count == 1)
        if case .invalid(_, let error) = out[0] {
            #expect(error == .checksumMismatch(expected: 0x79, actual: 0x00))
        } else {
            Issue.record("invalid ではない")
        }
    }

    @Test("RX フィクスチャ全体を 1 本ずつ食わせると 15 フレーム + 電源 OFF になる")
    func replaysWholeCapture() throws {
        var assembler = makeAssembler()
        var frames = [ChronoFrame]()
        var powerOffs = 0
        var invalids = 0
        for data in try Fixtures.rx() {
            for output in assembler.append(data) {
                switch output {
                case .frame(let frame, _): frames.append(frame)
                case .powerOff: powerOffs += 1
                case .invalid: invalids += 1
                }
            }
        }
        #expect(frames.count == 15)
        #expect(powerOffs == 1)
        #expect(invalids == 0)
        #expect(frames.filter { $0.command == .fireReport }.count == 5)
    }
}

@Suite("DeviceKeys / ChronoUUIDs")
struct DeviceKeysTests {
    @Test("広告の manufacturer data から鍵を取り出す")
    func keysFromManufacturerData() {
        let keys = DeviceKeys(manufacturerData: Fixtures.manufacturerData)
        #expect(keys == DeviceKeys(key1: 0xC4, key2: 0x94))
    }

    @Test("company id が違う / 短い manufacturer data は拒否する")
    func rejectsForeignManufacturerData() {
        #expect(DeviceKeys(manufacturerData: Data([0x4C, 0x00, 0x12, 0x02, 0x00])) == nil)
        #expect(DeviceKeys(manufacturerData: Data([0x00, 0x05, 0x08, 0xC4])) == nil)
        #expect(DeviceKeys(manufacturerData: Data()) == nil)
    }

    @Test("鍵は hex 文字列で往復できる（永続化用）")
    func hexRoundTrip() {
        let keys = DeviceKeys(key1: 0xC4, key2: 0x94)
        #expect(keys.hexString == "c494")
        #expect(DeviceKeys(hexString: "c494") == keys)
        #expect(DeviceKeys(hexString: "c4") == nil)
    }

    @Test("広告名の前方一致とベンダプレフィックスで機器を判定する")
    func advertisementMatching() {
        #expect(ChronoUUIDs.matchesAdvertisedName("AC6000BT-009809"))
        #expect(ChronoUUIDs.matchesAdvertisedName("AC7000-BT-1234"))
        #expect(!ChronoUUIDs.matchesAdvertisedName("ACETECH-12345678"))
        #expect(ChronoUUIDs.matchesManufacturerData(Fixtures.manufacturerData))
        #expect(!ChronoUUIDs.matchesManufacturerData(Data([0x4C, 0x00])))
        #expect(ChronoUUIDs.matches(name: nil, manufacturerData: Fixtures.manufacturerData))
    }

    @Test("OTA characteristic は書き込み禁止リストに入っている")
    func otaIsForbidden() {
        #expect(ChronoUUIDs.isForbiddenWriteTarget(ChronoUUIDs.otaControlCharacteristic))
        #expect(!ChronoUUIDs.isForbiddenWriteTarget(ChronoUUIDs.writeCharacteristic))
    }
}

// MARK: - テスト用の小道具

extension Result where Failure == ChronoFrameError {
    /// 失敗理由（成功なら nil）。
    var failure: ChronoFrameError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
