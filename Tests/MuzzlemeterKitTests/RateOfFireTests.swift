import Foundation
import Testing
@testable import MuzzlemeterKit

@Suite("RateOfFire")
struct RateOfFireTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)
    /// `Date` は基準日からの秒数を `Double` で持つため、実際の日時（1e9 秒規模）では
    /// ミリ秒未満の丸め誤差が出る。RPS の比較はこの許容差で行う。
    private let tolerance = 1e-4

    private func timestamps(_ offsets: [TimeInterval]) -> [Date] {
        offsets.map { base.addingTimeInterval($0) }
    }

    @Test("空・単発では推定できない")
    func notEnoughData() {
        #expect(RateOfFire.estimateRPS(timestamps: []) == nil)
        #expect(RateOfFire.estimateRPS(timestamps: timestamps([0])) == nil)
    }

    @Test("等間隔 0.05 秒の 5 連射は 20 rps")
    func evenBurst() throws {
        let rps = try #require(RateOfFire.estimateRPS(timestamps: timestamps([0, 0.05, 0.10, 0.15, 0.20])))
        #expect(abs(rps - 20) < tolerance)
    }

    @Test("1.0 秒を超える間隔でバーストが切れ、直近のバーストだけが対象になる")
    func splitsOnGap() throws {
        // 前半はゆっくり 3 発、5 秒空けてから 0.1 秒間隔で 3 発。
        let rps = try #require(
            RateOfFire.estimateRPS(timestamps: timestamps([0, 0.5, 1.0, 6.0, 6.1, 6.2]))
        )
        // 直近バーストは [6.0, 6.1, 6.2] → 2 間隔 / 0.2 秒 = 10 rps
        #expect(abs(rps - 10) < tolerance)
    }

    @Test("直近が単発なら nil（前のバーストを混ぜない）")
    func lastShotAloneIsNil() {
        #expect(RateOfFire.estimateRPS(timestamps: timestamps([0, 0.1, 0.2, 10.0])) == nil)
    }

    @Test("閾値ちょうどの間隔は同じバーストに含める")
    func thresholdIsInclusive() throws {
        let rps = try #require(
            RateOfFire.estimateRPS(timestamps: timestamps([0, 1.0]), burstGapThreshold: 1.0)
        )
        #expect(abs(rps - 1.0) < tolerance)
        #expect(RateOfFire.estimateRPS(timestamps: timestamps([0, 1.0001]), burstGapThreshold: 1.0) == nil)
    }

    @Test("閾値は指定できる")
    func customThreshold() throws {
        let stamps = timestamps([0, 2.0, 4.0])
        #expect(RateOfFire.estimateRPS(timestamps: stamps) == nil)
        let rps = try #require(RateOfFire.estimateRPS(timestamps: stamps, burstGapThreshold: 3.0))
        #expect(abs(rps - 0.5) < tolerance)
    }

    @Test("入力順序に依存しない")
    func unsortedInput() throws {
        let shuffled = timestamps([0.20, 0, 0.10, 0.15, 0.05])
        let rps = try #require(RateOfFire.estimateRPS(timestamps: shuffled))
        #expect(abs(rps - 20) < tolerance)
    }

    @Test("Shot 配列からも推定できる")
    func fromShots() throws {
        let shots = timestamps([0, 0.25, 0.5]).map {
            Shot(timestamp: $0, velocityMetersPerSecond: 90)
        }
        let rps = try #require(RateOfFire.estimateRPS(shots: shots))
        #expect(abs(rps - 4) < tolerance)
    }

    @Test("latestBurst は直近バーストを昇順で返す")
    func latestBurstContents() {
        let burst = RateOfFire.latestBurst(timestamps: timestamps([0, 0.1, 5.0, 5.1, 5.2]))
        #expect(burst == timestamps([5.0, 5.1, 5.2]))
    }
}
