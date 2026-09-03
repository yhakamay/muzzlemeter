import Foundation
import Testing
@testable import MuzzlemeterKit

@Suite("EnergyLimit")
struct EnergyLimitTests {
    @Test("上限の 90 % 以下は安全")
    func safeBelowNinetyPercent() {
        #expect(EnergyLimit.margin(joules: 0.50, limitJoules: 0.98) == .safe)
        // ちょうど 90 %（0.882 J）は境界の内側 = 安全。
        #expect(EnergyLimit.margin(joules: 0.882, limitJoules: 0.98) == .safe)
    }

    @Test("上限の 90 % 超〜上限未満は注意")
    func cautionNearLimit() {
        #expect(EnergyLimit.margin(joules: 0.90, limitJoules: 0.98) == .caution)
        #expect(EnergyLimit.margin(joules: 0.9799, limitJoules: 0.98) == .caution)
    }

    @Test("上限ちょうどは超過（安全側に倒す）")
    func atLimitIsOver() {
        #expect(EnergyLimit.margin(joules: 0.98, limitJoules: 0.98) == .over)
        #expect(EnergyLimit.margin(joules: 1.20, limitJoules: 0.98) == .over)
    }

    @Test("上限 0 以下は判定しない（常に安全）")
    func noLimitMeansSafe() {
        #expect(EnergyLimit.margin(joules: 5.0, limitJoules: 0) == .safe)
        #expect(EnergyLimit.margin(joules: 5.0, limitJoules: -1) == .safe)
    }

    @Test("注意の幅は変えられる")
    func customCautionFraction() {
        // 幅 0 なら「注意」は存在せず、上限未満は全部安全。
        #expect(EnergyLimit.margin(joules: 0.979, limitJoules: 0.98, cautionFraction: 0) == .safe)
        // 幅 50 % なら 0.49 J 超で注意。
        #expect(EnergyLimit.margin(joules: 0.60, limitJoules: 0.98, cautionFraction: 0.5) == .caution)
    }

    @Test("速度と重量から直接判定できる")
    func marginFromVelocity() {
        // 0.25 g / 88.5 m/s ≒ 0.979 J → 上限 0.98 J の直前 = 注意。
        #expect(
            EnergyLimit.margin(
                massGrams: 0.25,
                velocityMetersPerSecond: 88.5,
                limitJoules: 0.98
            ) == .caution
        )
        // 0.25 g / 92.0 m/s ≒ 1.058 J → 超過。
        #expect(
            EnergyLimit.margin(
                massGrams: 0.25,
                velocityMetersPerSecond: 92.0,
                limitJoules: 0.98
            ) == .over
        )
    }

    @Test("余裕は上限との差、超過なら負")
    func headroom() {
        #expect(abs(EnergyLimit.headroomJoules(joules: 0.86, limitJoules: 0.98) - 0.12) < 1e-9)
        #expect(EnergyLimit.headroomJoules(joules: 1.10, limitJoules: 0.98) < 0)
    }

    @Test("上限に収まる最大初速")
    func maxVelocity() {
        let v = try! #require(EnergyLimit.maxVelocity(massGrams: 0.25, limitJoules: 0.98))
        // 逆算したエネルギーが上限に一致する。
        #expect(abs(Energy.joules(massGrams: 0.25, velocityMetersPerSecond: v) - 0.98) < 1e-9)
        #expect(EnergyLimit.maxVelocity(massGrams: 0, limitJoules: 0.98) == nil)
    }

    @Test("超過したショットを数える")
    func overLimitCount() {
        let shots = [88.0, 92.0, 95.0, 80.0].map {
            Shot(velocityMetersPerSecond: $0)
        }
        // 0.25 g で 0.98 J を越えるのは 92.0 / 95.0 の 2 発。
        #expect(
            EnergyLimit.overLimitCount(shots: shots, massGrams: 0.25, limitJoules: 0.98) == 2
        )
    }
}
