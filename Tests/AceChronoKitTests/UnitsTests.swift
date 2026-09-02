import Foundation
import Testing
@testable import AceChronoKit

@Suite("Units")
struct UnitsTests {
    @Test("m/s は恒等変換")
    func metersPerSecondIsIdentity() {
        #expect(SpeedUnit.metersPerSecond.value(fromMetersPerSecond: 91.2) == 91.2)
        #expect(SpeedUnit.metersPerSecond.metersPerSecond(from: 91.2) == 91.2)
    }

    @Test("100 m/s = 328.0839895 fps")
    func metersToFeet() {
        let fps = SpeedUnit.feetPerSecond.value(fromMetersPerSecond: 100)
        #expect(abs(fps - 328.0839895) < 1e-6)
    }

    @Test("往復変換で元に戻る")
    func roundTrip() {
        for unit in SpeedUnit.allCases {
            let converted = unit.value(fromMetersPerSecond: 87.5)
            #expect(abs(unit.metersPerSecond(from: converted) - 87.5) < 1e-9)
        }
    }

    @Test("表示は m/s が小数 1 桁、fps が 0 桁")
    func speedFormatting() {
        #expect(SpeedUnit.metersPerSecond.format(metersPerSecond: 91.24) == "91.2")
        #expect(SpeedUnit.metersPerSecond.formatted(metersPerSecond: 91.24) == "91.2 m/s")
        // 91.24 m/s = 299.34... fps → 四捨五入して 299
        #expect(SpeedUnit.feetPerSecond.format(metersPerSecond: 91.24) == "299")
        #expect(SpeedUnit.feetPerSecond.formatted(metersPerSecond: 91.24) == "299 fps")
    }

    @Test("SpeedUnit は Codable かつ rawValue で識別できる")
    func speedUnitCodable() throws {
        #expect(SpeedUnit.allCases.count == 2)
        let encoded = try JSONEncoder().encode(SpeedUnit.feetPerSecond)
        let decoded = try JSONDecoder().decode(SpeedUnit.self, from: encoded)
        #expect(decoded == .feetPerSecond)
        #expect(SpeedUnit(rawValue: "metersPerSecond") == .metersPerSecond)
    }

    @Test("RPS ↔ RPM は 60 倍")
    func rateOfFireConversion() {
        #expect(RateOfFireUnit.rps.value(fromRPS: 12.5) == 12.5)
        #expect(RateOfFireUnit.rpm.value(fromRPS: 12.5) == 750)
        #expect(abs(RateOfFireUnit.rpm.rps(from: 750) - 12.5) < 1e-9)
    }

    @Test("ROF の表示桁数")
    func rateOfFireFormatting() {
        #expect(RateOfFireUnit.rps.formatted(rps: 12.53) == "12.5 rps")
        #expect(RateOfFireUnit.rpm.formatted(rps: 12.53) == "752 rpm")
    }
}
