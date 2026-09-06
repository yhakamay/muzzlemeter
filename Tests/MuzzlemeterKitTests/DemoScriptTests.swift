import Foundation
import Testing
@testable import MuzzlemeterKit

/// デモモードが流す射撃列。
///
/// **同じデコーダを通ること**が肝心なので、期待値は「合成に使った m/s」ではなく
/// 「実プロトコルのバイト列を `MuzzlemeterDecoder` に食わせて出てきた m/s」で書く。
@Suite("DemoScript")
struct DemoScriptTests {
    private let keys = DemoScript.keys

    private let characteristic = ChronoUUIDs.notifyCharacteristic

    /// スクリプトのバイト列を実機と同じデコーダに通して、出てきたショットを返す。
    private func decodedShots() -> [Shot] {
        let decoder = MuzzlemeterDecoder(keys: keys)
        var shots = [Shot]()
        for entry in DemoScript.script().entries {
            for event in decoder.decode(characteristic: characteristic, data: entry.data) {
                if case .shot(let shot) = event { shots.append(shot) }
            }
        }
        return shots
    }

    @Test("実プロトコルのフレームとしてデコードできる")
    func decodesThroughTheRealDecoder() {
        let shots = decodedShots()
        #expect(shots.count == DemoScript.allVelocities.count)
    }

    @Test("弾速はエアソフトとして妥当な範囲（0.20 g で 0.98 J 未満）")
    func velocitiesArePlausible() {
        let shots = decodedShots()
        for shot in shots {
            let speed = shot.velocityMetersPerSecond
            // ハンドスローの実キャプチャ（3 m/s 前後）ではなく、電動ガンの実勢。
            #expect(speed > 80 && speed < 100)
            // 0.20 g での動能。日本の 0.98 J を越えない見本にしてある
            // （デモが「規制上限を越えた状態」を既定にしてしまわないため）。
            let joules = Energy.joules(massGrams: 0.20, velocityMetersPerSecond: speed)
            #expect(joules < 0.98)
        }
    }

    @Test("弾速にばらつきがある（統計が意味を持つ）")
    func velocitiesHaveSpread() throws {
        let stats = SessionStats.compute(shots: decodedShots(), massGrams: 0.20)
        // 完全に一定だと SD も全距も 0 になり、統計カードが壊れて見える。
        #expect(try #require(stats.sampleStandardDeviation) > 0.3)
        #expect(try #require(stats.extremeSpread) > 1.0)
    }

    @Test("単発の後にバーストがある")
    func hasSemiAutoThenABurst() {
        let entries = DemoScript.script().entries
        let fireOffsets = entries.compactMap { entry -> TimeInterval? in
            let bytes = [UInt8](entry.data)
            guard bytes.count >= 3, bytes[0] == ChronoFrame.header,
                  bytes[2] == ChronoCommand.fireReport.rawValue
            else { return nil }
            return entry.offsetSeconds
        }
        #expect(fireOffsets.count == DemoScript.allVelocities.count)

        let semiCount = DemoScript.semiAutoVelocities.count
        // 単発は 1 秒以上あく。
        for index in 1..<semiCount {
            #expect(fireOffsets[index] - fireOffsets[index - 1] > 1.0)
        }
        // バーストは 0.1 秒未満の間隔（≒13 rps）。
        for index in (semiCount + 1)..<fireOffsets.count {
            #expect(fireOffsets[index] - fireOffsets[index - 1] < 0.1)
        }
    }

    @Test("先頭に ACK と現在の弾（0.20 g）が入っている")
    func startsWithHandshakeAndAmmo() {
        let decoder = MuzzlemeterDecoder(keys: keys)
        var sawAck = false
        var ammo: AmmoRecord?
        for entry in DemoScript.script().entries {
            for event in decoder.decode(characteristic: characteristic, data: entry.data) {
                switch event {
                case .ack: sawAck = true
                case .ammo(let record): ammo = record
                default: break
                }
            }
        }
        #expect(sawAck)
        // 本体の弾設定が 0.20 g でないと、デモ中ずっと「弾設定の食い違い」の帯が出る。
        #expect(ammo?.weightGrams == DemoScript.deviceBBWeightGrams)
    }

    /// デモの擬似本体は「本体内ログ 0 件」と答える。取り込みの帯を出さないため。
    @Test("デモのトランスポートは本体内ログを 0 件と答える")
    func demoTransportReportsNoDeviceLog() async throws {
        let transport = DemoScript.makeTransport()
        let events = transport.events
        try await transport.connect(to: ReplayTransport.demoPeripheral.id)
        try await transport.subscribe(to: ChronoUUIDs.notifyCharacteristic)

        let request = ChronoFrame(command: .logCount, payload: []).encode(keys: keys)
        try await transport.write(request, to: ChronoUUIDs.writeCharacteristic, withResponse: false)

        let decoder = MuzzlemeterDecoder(keys: keys)
        var reported: Int?
        for await event in events {
            guard case .value(_, let data) = event else { continue }
            for decoded in decoder.decode(characteristic: characteristic, data: data) {
                if case .logCount(let count) = decoded { reported = count }
            }
            if reported != nil { break }
        }
        #expect(reported == 0)
        await transport.shutdown()
    }
}
