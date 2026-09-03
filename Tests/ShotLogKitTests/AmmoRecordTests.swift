import Foundation
import Testing
@testable import ShotLogKit

@Suite("AmmoRecord（重量スケールの寛容な読み取り）")
struct AmmoRecordTests {
    private func record(rawWeight: UInt16, slot: Int = 1) -> AmmoRecord {
        AmmoRecord(
            slot: slot,
            rawDiameter: 600,
            rawWeight: rawWeight,
            isCurrent: true,
            marker: 0x01
        )
    }

    @Test("キャプチャのプリセット（×100）はそのまま実在重量になる")
    func hundredScale() {
        // 20 / 25 / 43 / 45 / 88 → 0.20 / 0.25 / 0.43 / 0.45 / 0.88 g
        let expected: [(UInt16, Double)] = [(20, 0.20), (25, 0.25), (43, 0.43), (45, 0.45), (88, 0.88)]
        for (raw, grams) in expected {
            #expect(abs((record(rawWeight: raw).weightGrams ?? 0) - grams) < 1e-9)
        }
    }

    @Test("実機の自発通知（×1000）も実在重量として読める")
    func thousandScale() {
        // 実機で観測された 200 は ×100 なら 2.00 g で実在しない。×1000 の 0.20 g と読む。
        #expect(abs((record(rawWeight: 200).weightGrams ?? 0) - 0.20) < 1e-9)
        #expect(abs((record(rawWeight: 250).weightGrams ?? 0) - 0.25) < 1e-9)
        #expect(abs((record(rawWeight: 980).weightGrams ?? 0) - 0.98) < 1e-9)
    }

    @Test("境目は 100（未満なら ×100、以上なら ×1000）")
    func scaleBoundary() {
        // 99 → 0.99 g（×100）
        #expect(abs((record(rawWeight: 99).weightGrams ?? 0) - 0.99) < 1e-9)
        // 100 → 0.10 g（×1000）
        #expect(abs((record(rawWeight: 100).weightGrams ?? 0) - 0.10) < 1e-9)
    }

    @Test("未設定（0）と実在しない重量は nil にする")
    func implausibleValuesAreNil() {
        #expect(record(rawWeight: 0).weightGrams == nil)
        // 5 → 0.05 g。6 mm BB には存在しない軽さなので読み替えない。
        #expect(record(rawWeight: 5).weightGrams == nil)
        // 9999 → 9.999 g。存在しない。
        #expect(record(rawWeight: 9_999).weightGrams == nil)
    }

    @Test("直径は ×100 のまま（全スロットで 6.00 mm）")
    func diameter() {
        #expect(abs(record(rawWeight: 20).diameterMm - 6.0) < 1e-9)
    }
}
