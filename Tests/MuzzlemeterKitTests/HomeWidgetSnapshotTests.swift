import Foundation
import Testing
@testable import MuzzlemeterKit

@Suite("HomeWidgetSnapshot")
struct HomeWidgetSnapshotTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "muzzlemeter.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("保存前は nil")
    func loadsNilBeforeSave() {
        #expect(HomeWidgetSnapshotStore.load(from: makeDefaults()) == nil)
    }

    @Test("保存した値をそのまま読み戻せる")
    func roundTrips() {
        let defaults = makeDefaults()
        let snapshot = HomeWidgetSnapshot(
            title: "スプリング交換後",
            gunName: "次世代 M4",
            shotCount: 6,
            meanSpeedMetersPerSecond: 89.0,
            meanJoules: 0.99,
            overLimitCount: 2,
            endedAt: Date(timeIntervalSince1970: 1_700_000_000),
            speedUnit: .metersPerSecond
        )
        HomeWidgetSnapshotStore.save(snapshot, to: defaults)
        let loaded = HomeWidgetSnapshotStore.load(from: defaults)
        #expect(loaded == snapshot)
    }

    @Test("後から保存した値が前の値を置き換える（常に最新だけ持つ）")
    func overwritesPreviousSnapshot() {
        let defaults = makeDefaults()
        let first = HomeWidgetSnapshot(
            title: "1 回目", gunName: "銃 A", shotCount: 3,
            meanSpeedMetersPerSecond: 80, meanJoules: 0.8, overLimitCount: 0,
            endedAt: Date(), speedUnit: .metersPerSecond
        )
        let second = HomeWidgetSnapshot(
            title: "2 回目", gunName: "銃 B", shotCount: 5,
            meanSpeedMetersPerSecond: 90, meanJoules: 0.95, overLimitCount: 1,
            endedAt: Date(), speedUnit: .feetPerSecond
        )
        HomeWidgetSnapshotStore.save(first, to: defaults)
        HomeWidgetSnapshotStore.save(second, to: defaults)
        #expect(HomeWidgetSnapshotStore.load(from: defaults) == second)
    }

    @Test("整形済みの表示文字列")
    func formattedFields() {
        let snapshot = HomeWidgetSnapshot(
            title: "テスト", gunName: "銃", shotCount: 4,
            meanSpeedMetersPerSecond: 91.2, meanJoules: 1.03, overLimitCount: 0,
            endedAt: Date(), speedUnit: .metersPerSecond
        )
        #expect(snapshot.formattedMeanSpeed == "91.2 m/s")
        #expect(snapshot.formattedMeanJoules == "1.03 J")
    }

    @Test("0 発ぶんの平均は nil のまま整形されない")
    func nilMeansNoFormattedValue() {
        let snapshot = HomeWidgetSnapshot(
            title: "テスト", gunName: "銃", shotCount: 0,
            meanSpeedMetersPerSecond: nil, meanJoules: nil, overLimitCount: 0,
            endedAt: Date(), speedUnit: .metersPerSecond
        )
        #expect(snapshot.formattedMeanSpeed == nil)
        #expect(snapshot.formattedMeanJoules == nil)
    }
}
