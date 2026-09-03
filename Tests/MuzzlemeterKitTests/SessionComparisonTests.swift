import Foundation
import Testing
@testable import MuzzlemeterKit

@Suite("SessionComparison")
struct SessionComparisonTests {
    private func column(
        _ id: String,
        velocities: [Double],
        massGrams: Double = 0.25,
        overLimitCount: Int = 0
    ) -> ComparisonColumn {
        let shots = velocities.enumerated().map { index, v in
            Shot(
                timestamp: Date(timeIntervalSince1970: 1_000 + Double(index)),
                velocityMetersPerSecond: v
            )
        }
        return ComparisonColumn(
            id: id,
            stats: SessionStats.compute(shots: shots, massGrams: massGrams),
            overLimitCount: overLimitCount
        )
    }

    @Test("ばらつきと超過発数だけが「小さいほうが良い」")
    func preferences() {
        #expect(ComparisonMetric.sampleStandardDeviation.preference == .lower)
        #expect(ComparisonMetric.extremeSpread.preference == .lower)
        #expect(ComparisonMetric.overLimitCount.preference == .lower)
        #expect(ComparisonMetric.mean.preference == .none)
        #expect(ComparisonMetric.max.preference == .none)
        #expect(ComparisonMetric.min.preference == .none)
        #expect(ComparisonMetric.count.preference == .none)
        #expect(ComparisonMetric.meanJoules.preference == .none)
    }

    @Test("向きの無い行には印を付けない")
    func noHighlightWithoutPreference() {
        let columns = [column("a", velocities: [90, 91]), column("b", velocities: [80, 81])]
        let values = ComparisonTable.values(of: .mean, columns: columns)
        #expect(ComparisonTable.bestIndices(of: .mean, values: values).isEmpty)
    }

    @Test("SD が最も小さい列に印が付く")
    func lowestStandardDeviationWins() {
        let columns = [
            column("a", velocities: [88, 92]),      // SD = 2.83
            column("b", velocities: [90, 90.5]),    // SD = 0.35
            column("c", velocities: [80, 100]),     // SD = 14.1
        ]
        let values = ComparisonTable.values(of: .sampleStandardDeviation, columns: columns)
        #expect(ComparisonTable.bestIndices(of: .sampleStandardDeviation, values: values) == [1])
    }

    @Test("同点は両方に印を付ける")
    func tiesAreBothMarked() {
        let values: [Double?] = [1.0, 1.0, 3.0]
        #expect(ComparisonTable.bestIndices(of: .extremeSpread, values: values) == [0, 1])
    }

    @Test("全部同じ値なら印を付けない")
    func allEqualMeansNoHighlight() {
        let values: [Double?] = [2.0, 2.0, 2.0]
        #expect(ComparisonTable.bestIndices(of: .extremeSpread, values: values).isEmpty)
    }

    @Test("比べる相手がいない（値が 1 つだけ）なら印を付けない")
    func singleValueMeansNoHighlight() {
        let values: [Double?] = [1.5, nil, nil]
        #expect(ComparisonTable.bestIndices(of: .sampleStandardDeviation, values: values).isEmpty)
    }

    @Test("nil は比較から外す")
    func nilValuesAreIgnored() {
        let values: [Double?] = [nil, 4.0, 2.0]
        #expect(ComparisonTable.bestIndices(of: .sampleStandardDeviation, values: values) == [2])
    }

    @Test("超過発数は 0 が最良")
    func overLimitCountLowerIsBetter() {
        let columns = [
            column("a", velocities: [90, 91], overLimitCount: 3),
            column("b", velocities: [90, 91], overLimitCount: 0),
        ]
        let values = ComparisonTable.values(of: .overLimitCount, columns: columns)
        #expect(values == [3, 0])
        #expect(ComparisonTable.bestIndices(of: .overLimitCount, values: values) == [1])
    }

    @Test("行の値はセッション統計から取り出される")
    func valuesComeFromStats() throws {
        let columns = [column("a", velocities: [88, 90, 92, 94, 96], massGrams: 0.20)]
        #expect(ComparisonTable.values(of: .count, columns: columns) == [5])
        let mean = try #require(ComparisonTable.values(of: .mean, columns: columns)[0])
        #expect(abs(mean - 92) < 1e-9)
        let es = try #require(ComparisonTable.values(of: .extremeSpread, columns: columns)[0])
        #expect(abs(es - 8) < 1e-9)
        let sd = try #require(ComparisonTable.values(of: .sampleStandardDeviation, columns: columns)[0])
        #expect(abs(sd - 10.0.squareRoot()) < 1e-9)
        #expect(ComparisonTable.values(of: .meanJoules, columns: columns)[0] != nil)
    }

    @Test("SD と ES は速度の「差」（fps 換算でオフセットを持たない）")
    func differenceMetrics() {
        #expect(ComparisonMetric.sampleStandardDeviation.isSpeedDifference)
        #expect(ComparisonMetric.extremeSpread.isSpeedDifference)
        #expect(!ComparisonMetric.mean.isSpeedDifference)
        #expect(!ComparisonMetric.max.isSpeedDifference)
    }

    @Test("まとめて求めても 1 行ずつと同じ")
    func bulkMatchesPerRow() {
        let columns = [
            column("a", velocities: [88, 92], overLimitCount: 1),
            column("b", velocities: [90, 90.5], overLimitCount: 0),
        ]
        let bulk = ComparisonTable.bestIndicesByMetric(columns: columns)
        for metric in ComparisonTable.metrics {
            let values = ComparisonTable.values(of: metric, columns: columns)
            #expect(bulk[metric] == ComparisonTable.bestIndices(of: metric, values: values))
        }
    }
}
