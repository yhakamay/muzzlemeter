import Foundation
import Testing
@testable import AceChronoKit

@Suite("SessionStats")
struct SessionStatsTests {
    private func shots(_ velocities: [Double], rof: [Double?]? = nil) -> [Shot] {
        velocities.enumerated().map { index, v in
            Shot(
                timestamp: Date(timeIntervalSince1970: 1_000 + Double(index)),
                velocityMetersPerSecond: v,
                rateOfFireRPS: rof?[index]
            )
        }
    }

    @Test("0 発なら全て nil")
    func emptyInput() {
        let stats = SessionStats.compute(shots: [], massGrams: 0.25)
        #expect(stats.count == 0)
        #expect(stats.isEmpty)
        #expect(stats.meanMetersPerSecond == nil)
        #expect(stats.sampleStandardDeviation == nil)
        #expect(stats.extremeSpread == nil)
        #expect(stats.massGrams == 0.25)
    }

    @Test("1 発では SD が定義できない")
    func singleShotHasNoStandardDeviation() {
        let stats = SessionStats.compute(shots: shots([90]), massGrams: 0.20)
        #expect(stats.count == 1)
        #expect(stats.meanMetersPerSecond == 90)
        #expect(stats.maxMetersPerSecond == 90)
        #expect(stats.minMetersPerSecond == 90)
        #expect(stats.sampleStandardDeviation == nil)
        #expect(stats.extremeSpread == 0)
    }

    @Test("既知の値: [88, 90, 92, 94, 96] の標本 SD は sqrt(10)")
    func knownValues() throws {
        let stats = SessionStats.compute(shots: shots([88, 90, 92, 94, 96]), massGrams: 0.20)
        #expect(stats.count == 5)
        #expect(stats.meanMetersPerSecond == 92)
        #expect(stats.maxMetersPerSecond == 96)
        #expect(stats.minMetersPerSecond == 88)
        #expect(stats.extremeSpread == 8)

        // 偏差 -4,-2,0,2,4 → 二乗和 40、n-1 = 4 → 分散 10
        let sd = try #require(stats.sampleStandardDeviation)
        #expect(abs(sd - 10.0.squareRoot()) < 1e-9)
    }

    @Test("母集団 SD ではなく標本 SD（n-1）を使う")
    func usesSampleNotPopulationStandardDeviation() throws {
        // [10, 20]: 標本 SD = sqrt(50) ≈ 7.0711、母集団 SD = 5
        let stats = SessionStats.compute(shots: shots([10, 20]), massGrams: 0.20)
        let sd = try #require(stats.sampleStandardDeviation)
        #expect(abs(sd - 50.0.squareRoot()) < 1e-9)
        #expect(abs(sd - 5) > 1)
    }

    @Test("ジュールは 1 発ずつ計算した平均であり、平均速度からの計算ではない")
    func meanJoulesAveragesPerShot() throws {
        // 0.20g, [80, 100] → J = 0.64, 1.00 → 平均 0.82
        // 平均速度 90 から計算すると 0.81 になり一致しない。
        let stats = SessionStats.compute(shots: shots([80, 100]), massGrams: 0.20)
        let mean = try #require(stats.meanJoules)
        #expect(abs(mean - 0.82) < 1e-9)

        let maxJ = try #require(stats.maxJoules)
        #expect(abs(maxJ - 1.0) < 1e-9)
    }

    @Test("本体が報告した ROF の平均を取る。報告のあるショットだけを対象にする")
    func meanRateOfFireUsesReportedValuesOnly() throws {
        let stats = SessionStats.compute(
            shots: shots([90, 91, 92], rof: [nil, 12.0, 14.0]),
            massGrams: 0.25
        )
        let rof = try #require(stats.meanRateOfFireRPS)
        #expect(abs(rof - 13.0) < 1e-9)
    }

    @Test("ROF の報告が 1 発も無ければ nil")
    func meanRateOfFireNilWhenNothingReported() {
        let stats = SessionStats.compute(shots: shots([90, 91]), massGrams: 0.25)
        #expect(stats.meanRateOfFireRPS == nil)
    }
}
