import Foundation
import Testing
@testable import ShotLogKit

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

    @Test("m/s は本体 LCD に合わせて切り捨て表示する")
    func metersPerSecondTruncates() {
        // 実機での対応（raw 325 / 278 / 375 → LCD 3.2 / 2.7 / 3.7）。
        #expect(SpeedUnit.metersPerSecond.format(metersPerSecond: 3.25) == "3.2")
        #expect(SpeedUnit.metersPerSecond.format(metersPerSecond: 2.78) == "2.7")
        #expect(SpeedUnit.metersPerSecond.format(metersPerSecond: 3.75) == "3.7")
        // 端数が無い値は落ちない（浮動小数の誤差で 2.7 にならないこと）。
        #expect(SpeedUnit.metersPerSecond.format(metersPerSecond: 2.8) == "2.8")
        #expect(SpeedUnit.metersPerSecond.format(metersPerSecond: 91.0) == "91.0")
        // fps は本体に表示が無いので従来どおり四捨五入。
        #expect(SpeedUnit.feetPerSecond.format(metersPerSecond: 91.24) == "299")
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
