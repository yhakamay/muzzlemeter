import Foundation
import Testing
@testable import MuzzlemeterKit

@Suite("LiveActivityContent")
struct LiveActivityContentTests {
    @Test("1 発も無ければ待機表示")
    func idleBeforeFirstShot() {
        let content = LiveActivityContent.derive(
            shots: [],
            massGrams: 0.25,
            speedUnit: .metersPerSecond,
            energyLimitJoules: 0.98,
            target: nil,
            gunName: "次世代 M4"
        )
        #expect(content.speedText == "—")
        #expect(content.joulesText == "—")
        #expect(content.shotCountText == "0")
        #expect(content.meanSpeedText == nil)
        #expect(content.margin == .safe)
        #expect(content.gunName == "次世代 M4")
    }

    @Test("直近 1 発と平均・段階が反映される")
    func derivesFromShots() {
        let shots = [82.0, 84.0, 96.0].map { Shot(velocityMetersPerSecond: $0) }
        let content = LiveActivityContent.derive(
            shots: shots,
            massGrams: 0.25,
            speedUnit: .metersPerSecond,
            energyLimitJoules: 0.98,
            target: nil,
            gunName: "次世代 M4"
        )
        // 直近 1 発は 96.0 m/s（0.25 g で 1.152 J、上限超過）。
        #expect(content.speedText == "96.0")
        #expect(content.margin == .over)
        #expect(content.shotCountText == "3")
        #expect(content.meanSpeedText != nil)
    }

    @Test("N 発モードでは「n / N」表示")
    func shotCountWithTarget() {
        let shots = (0..<3).map { _ in Shot(velocityMetersPerSecond: 80.0) }
        let content = LiveActivityContent.derive(
            shots: shots,
            massGrams: 0.25,
            speedUnit: .metersPerSecond,
            energyLimitJoules: 0.98,
            target: ShotTarget(10),
            gunName: "グロック 18C"
        )
        #expect(content.shotCountText == "3 / 10")
    }

    @Test("fps 単位でも整形が切り替わる")
    func fpsUnit() {
        let content = LiveActivityContent.derive(
            shots: [Shot(velocityMetersPerSecond: 91.44)],
            massGrams: 0.25,
            speedUnit: .feetPerSecond,
            energyLimitJoules: 0.98,
            target: nil,
            gunName: "テスト銃"
        )
        #expect(content.speedUnitSymbol == "fps")
        // 91.44 m/s ≒ 300 fps。
        #expect(content.speedText == "300")
    }
}

@Suite("LiveActivityUpdateThrottle")
struct LiveActivityUpdateThrottleTests {
    @Test("初回更新は常に許可される")
    func firstUpdateAlwaysAllowed() {
        let throttle = LiveActivityUpdateThrottle(minimumInterval: 1.0)
        #expect(throttle.shouldUpdate(now: Date(), lastUpdate: nil))
    }

    @Test("最小間隔未満の連続更新は抑える（フルオート想定）")
    func suppressesRapidUpdates() {
        let throttle = LiveActivityUpdateThrottle(minimumInterval: 1.0)
        let last = Date()
        #expect(!throttle.shouldUpdate(now: last.addingTimeInterval(0.3), lastUpdate: last))
        #expect(throttle.shouldUpdate(now: last.addingTimeInterval(1.0), lastUpdate: last))
        #expect(throttle.shouldUpdate(now: last.addingTimeInterval(2.5), lastUpdate: last))
    }
}
