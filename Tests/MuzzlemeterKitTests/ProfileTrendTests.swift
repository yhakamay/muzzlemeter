import Foundation
import Testing
@testable import MuzzlemeterKit

@Suite("ProfileTrend")
struct ProfileTrendTests {
    private func sample(
        _ id: String,
        daysAgo: Double,
        velocities: [Double],
        massGrams: Double = 0.25,
        temperatureC: Double? = nil
    ) -> ProfileTrendSample {
        let date = Date(timeIntervalSince1970: 1_000_000 - daysAgo * 86_400)
        let shots = velocities.enumerated().map { index, v in
            Shot(timestamp: date.addingTimeInterval(Double(index)), velocityMetersPerSecond: v)
        }
        return ProfileTrendSample(
            id: id,
            date: date,
            massGrams: massGrams,
            temperatureC: temperatureC,
            stats: SessionStats.compute(shots: shots, massGrams: massGrams)
        )
    }

    @Test("点は古い順に並ぶ")
    func pointsAreSortedByDate() {
        let points = ProfileTrend.points(from: [
            sample("new", daysAgo: 1, velocities: [90, 91]),
            sample("old", daysAgo: 10, velocities: [88, 89]),
        ])
        #expect(points.map(\.id) == ["old", "new"])
    }

    @Test("1 発も無いセッションは点にしない")
    func emptySessionsAreDropped() {
        let empty = ProfileTrendSample(
            id: "empty",
            date: Date(timeIntervalSince1970: 1_000),
            massGrams: 0.25,
            temperatureC: 20,
            stats: .empty(massGrams: 0.25)
        )
        let points = ProfileTrend.points(from: [empty, sample("a", daysAgo: 1, velocities: [90])])
        #expect(points.map(\.id) == ["a"])
    }

    @Test("点は平均と SD を持ち、エラーバーの上下を出せる")
    func pointCarriesMeanAndSD() throws {
        let points = ProfileTrend.points(from: [sample("a", daysAgo: 1, velocities: [88, 90, 92, 94, 96])])
        let point = try #require(points.first)
        #expect(point.count == 5)
        #expect(abs(point.meanMetersPerSecond - 92) < 1e-9)
        let sd = try #require(point.sampleStandardDeviation)
        #expect(abs(sd - 10.0.squareRoot()) < 1e-9)
        #expect(abs(point.upperMetersPerSecond - (92 + sd)) < 1e-9)
        #expect(abs(point.lowerMetersPerSecond - (92 - sd)) < 1e-9)
    }

    @Test("1 発だけのセッションは SD が無く、エラーバーが潰れる")
    func singleShotHasNoErrorBar() throws {
        let point = try #require(ProfileTrend.points(from: [sample("a", daysAgo: 1, velocities: [90])]).first)
        #expect(point.sampleStandardDeviation == nil)
        #expect(point.lowerMetersPerSecond == point.upperMetersPerSecond)
    }

    @Test("気温のある点だけを散布図に出す")
    func temperaturePointsFilter() {
        let points = ProfileTrend.points(from: [
            sample("a", daysAgo: 3, velocities: [90], temperatureC: 12),
            sample("b", daysAgo: 2, velocities: [91]),
            sample("c", daysAgo: 1, velocities: [92], temperatureC: 25),
        ])
        #expect(ProfileTrend.temperaturePoints(points).map(\.id) == ["a", "c"])
        #expect(ProfileTrend.temperaturePoints(points).count < ProfileTrend.minimumTemperaturePoints)
    }

    @Test("BB 重量が変われば色分けする（0.001 g 未満の差は同じ扱い）")
    func massVariation() {
        let same = ProfileTrend.points(from: [
            sample("a", daysAgo: 2, velocities: [90], massGrams: 0.25),
            sample("b", daysAgo: 1, velocities: [90], massGrams: 0.2500001),
        ])
        #expect(!ProfileTrend.massGramsVaries(same))

        let mixed = ProfileTrend.points(from: [
            sample("a", daysAgo: 2, velocities: [90], massGrams: 0.25),
            sample("b", daysAgo: 1, velocities: [90], massGrams: 0.20),
        ])
        #expect(ProfileTrend.massGramsVaries(mixed))
        #expect(ProfileTrend.massGramsValues(mixed) == [0.20, 0.25])
    }

    @Test("まとめの平均は発数で重み付けする")
    func summaryMeanIsWeighted() throws {
        let summary = ProfileTrend.summary(from: [
            sample("a", daysAgo: 2, velocities: [90, 90, 90, 90]),   // 4 発
            sample("b", daysAgo: 1, velocities: [100]),              // 1 発
        ])
        #expect(summary.sessionCount == 2)
        #expect(summary.shotCount == 5)
        let mean = try #require(summary.meanMetersPerSecond)
        #expect(abs(mean - 92) < 1e-9)   // (90*4 + 100) / 5
    }

    @Test("まとめの SD は全ショットを 1 つの標本として計算する")
    func summarySDMatchesPooledSample() throws {
        let all: [Double] = [88, 90, 92, 94, 96, 70, 72]
        let expected = SessionStats.compute(
            shots: all.enumerated().map { Shot(timestamp: Date(timeIntervalSince1970: Double($0.offset)), velocityMetersPerSecond: $0.element) },
            massGrams: 0.25
        )
        let summary = ProfileTrend.summary(from: [
            sample("a", daysAgo: 2, velocities: [88, 90, 92, 94, 96]),
            sample("b", daysAgo: 1, velocities: [70, 72]),
        ])
        let sd = try #require(summary.sampleStandardDeviation)
        let expectedSD = try #require(expected.sampleStandardDeviation)
        #expect(abs(sd - expectedSD) < 1e-9)
        let mean = try #require(summary.meanMetersPerSecond)
        let expectedMean = try #require(expected.meanMetersPerSecond)
        #expect(abs(mean - expectedMean) < 1e-9)
    }

    @Test("空のプロファイルのまとめ")
    func emptySummary() {
        #expect(ProfileTrend.summary(from: []) == .empty)
        let onlyEmpty = ProfileTrendSample(
            id: "e",
            date: Date(timeIntervalSince1970: 5),
            massGrams: 0.25,
            temperatureC: nil,
            stats: .empty(massGrams: 0.25)
        )
        let summary = ProfileTrend.summary(from: [onlyEmpty])
        #expect(summary.sessionCount == 1)
        #expect(summary.shotCount == 0)
        #expect(summary.meanMetersPerSecond == nil)
        #expect(summary.lastSessionDate == onlyEmpty.date)
    }

    @Test("最後のセッションの日は最新の 1 件")
    func lastSessionDate() throws {
        let summary = ProfileTrend.summary(from: [
            sample("old", daysAgo: 10, velocities: [90]),
            sample("new", daysAgo: 1, velocities: [90]),
        ])
        let last = try #require(summary.lastSessionDate)
        #expect(abs(last.timeIntervalSince1970 - (1_000_000 - 86_400)) < 1e-6)
    }

    @Test("タップした位置にいちばん近い点を返す")
    func nearestPoint() throws {
        let points = ProfileTrend.points(from: [
            sample("old", daysAgo: 10, velocities: [90]),
            sample("new", daysAgo: 1, velocities: [92]),
        ])
        let target = Date(timeIntervalSince1970: 1_000_000 - 2 * 86_400)
        #expect(ProfileTrend.nearestPoint(to: target, in: points)?.id == "new")
        #expect(ProfileTrend.nearestPoint(to: target, in: [])?.id == nil)
    }
}
