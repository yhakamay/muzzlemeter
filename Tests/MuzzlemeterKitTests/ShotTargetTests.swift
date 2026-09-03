import Foundation
import Testing
@testable import MuzzlemeterKit

@Suite("ShotTarget（N 発モード）")
struct ShotTargetTests {
    @Test("nil / 0 / 負数は目標として成立しない（手動で締める）")
    func invalidTargets() {
        #expect(ShotTarget(nil) == nil)
        #expect(ShotTarget(0) == nil)
        #expect(ShotTarget(-3) == nil)
    }

    @Test("ちょうど N 発目で締まる")
    func reachedExactly() {
        let target = try! #require(ShotTarget(10))
        #expect(!target.isReached(shotCount: 9))
        #expect(target.isReached(shotCount: 10))
    }

    @Test("超えても締まる（フルオートで行き過ぎたとき）")
    func reachedOvershoot() {
        // 10 発設定でトリガを引きっぱなしにすると 12 発届くことがある。
        // 「ちょうど」だけを見ていると永遠に締まらない。
        let target = try! #require(ShotTarget(10))
        #expect(target.isReached(shotCount: 12))
    }

    @Test("残り発数は 0 で止まる")
    func remaining() {
        let target = try! #require(ShotTarget(10))
        #expect(target.remaining(shotCount: 0) == 10)
        #expect(target.remaining(shotCount: 7) == 3)
        #expect(target.remaining(shotCount: 10) == 0)
        #expect(target.remaining(shotCount: 12) == 0)
    }

    @Test("進捗は 0…1 に収まる")
    func progress() {
        let target = try! #require(ShotTarget(4))
        #expect(target.progress(shotCount: 0) == 0)
        #expect(abs(target.progress(shotCount: 1) - 0.25) < 1e-9)
        #expect(target.progress(shotCount: 4) == 1)
        #expect(target.progress(shotCount: 9) == 1)
    }

    @Test("1 発モードも作れる")
    func singleShot() {
        let target = try! #require(ShotTarget(1))
        #expect(!target.isReached(shotCount: 0))
        #expect(target.isReached(shotCount: 1))
    }
}
