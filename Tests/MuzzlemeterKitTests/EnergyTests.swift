import Testing
@testable import MuzzlemeterKit

@Suite("Energy")
struct EnergyTests {
    @Test("0.20g @ 90 m/s ≈ 0.81 J")
    func lightBBAt90() {
        let j = Energy.joules(massGrams: 0.20, velocityMetersPerSecond: 90)
        #expect(abs(j - 0.81) < 0.0001)
    }

    @Test("0.25g @ 100 m/s = 1.25 J")
    func mediumBBAt100() {
        let j = Energy.joules(massGrams: 0.25, velocityMetersPerSecond: 100)
        #expect(abs(j - 1.25) < 0.0001)
    }

    @Test("速度 0 ならエネルギーも 0")
    func zeroVelocity() {
        #expect(Energy.joules(massGrams: 0.20, velocityMetersPerSecond: 0) == 0)
    }
}
