import Foundation
import ShotLogKit

/// 「その回の計測条件」。BB 重量・ガス種別・ホップ設定の 3 つ。
///
/// 銃（`GunProfile`）ではなくセッションに属する値。同じ銃でも弾を変えれば
/// ジュールは変わるし、ガスを変えれば初速が変わる。プロファイルは**既定値**を
/// 持つだけで、実際に効いているのはセッションが持つこの値。
///
/// 値型にしてあるのは、待機中（まだセッションが無い）の「次に始まる条件」を
/// `@Model` を作らずに持ち回せるようにするため。
struct SessionVariables: Equatable, Sendable {
    var bbWeightGrams: Double = 0.25
    var gasType: GasType = .hfc134a
    /// 自由記述（「3」「少し強め」など）。空文字は「記録なし」。
    var hopSetting: String = ""
    /// 目標発数。`nil` は「手動で締める」。
    ///
    /// その回だけ「20 発だけ測る」と決めることがあるので、プロファイルの既定値ではなく
    /// **セッションの条件**として持つ。
    var targetShotCount: Int?

    /// Live のピル直下に出す 1 行（`0.25 g · HFC134a · ホップ 3`）。
    ///
    /// 区分がガスでなければガス種別は出さない（意味が無い）し、ホップが空なら
    /// 「ホップ ―」のような空欄も出さない。**書いてあるものは全部意味がある**状態にする。
    func summary(category: PowerCategory) -> String {
        var parts = [GunProfile.weightLabel(bbWeightGrams)]
        if category.usesGas { parts.append(gasType.label) }
        let hop = hopSetting.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hop.isEmpty { parts.append(String(localized: "ホップ \(hop)")) }
        // 目標発数は待機中にも見えている必要がある（撃ち始めてからでは遅い）。
        if let target = ShotTarget(targetShotCount) {
            parts.append(String(localized: "目標 \(target.count) 発"))
        }
        return parts.joined(separator: " · ")
    }

    /// 入力の揺れ（前後の空白）を落としたもの。保存前に必ず通す。
    var normalized: SessionVariables {
        var copy = self
        copy.hopSetting = hopSetting.trimmingCharacters(in: .whitespacesAndNewlines)
        // 0 や負数は「目標なし」と同義なので、保存前に nil へ寄せる（比較のためにも要る）。
        copy.targetShotCount = ShotTarget(targetShotCount)?.count
        return copy
    }

    /// 目標発数（成立していれば）。
    var target: ShotTarget? { ShotTarget(targetShotCount) }
}
