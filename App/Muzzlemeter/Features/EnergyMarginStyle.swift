import MuzzlemeterKit
import SwiftUI

/// 規制上限に対する段階の**色と語**は `App/Shared/EnergyMarginTint.swift`
/// （`EnergyMargin.tint` / `chartTint` / `label` / `symbolName`）に置いてある。
/// アプリ本体だけでなくホーム画面ウィジェット・ライブアクティビティ（`MuzzlemeterWidgets`）
/// でも同じ色と語を使うため（`App/Shared` は両ターゲットのソースに入っている）。

/// 「上限 0.98 J · 余裕 0.12 J」の 1 行。
///
/// 上限そのものを**常に**出しているのが肝で、色だけだと「何 J を基準にした赤なのか」が
/// 分からない。越えているときは余裕ではなく超過分（`+0.05 J`）を出す。
struct EnergyLimitLine: View {
    let limitJoules: Double
    /// 上限までの余裕（J）。負なら超過分。まだ 1 発も無ければ `nil`。
    let headroomJoules: Double?
    let margin: EnergyMargin
    var font: Font = .footnote
    /// タップで用語説明を出すか（統計カードの中では出し、Live の見出しでは出さない）。
    var isExplainable = true

    @State private var isExplaining = false

    var body: some View {
        if isExplainable {
            Button { isExplaining = true } label: { line.contentShape(.rect) }
                .buttonStyle(.plain)
                .popover(isPresented: $isExplaining) { StatExplanation(term: .energyLimit) }
        } else {
            line
        }
    }

    private var line: some View {
        HStack(spacing: 4) {
            Image(systemName: margin.symbolName)
                .font(font)
            Text("上限 \(GunProfile.energyLimitLabel(limitJoules))")
                .font(font)
            if let headroom = headroomJoules {
                Text(verbatim: "·")
                    .font(font)
                    .foregroundStyle(.tertiary)
                if headroom >= 0 {
                    Text("余裕 \(JouleFormat.labeled(headroom))")
                        .font(font)
                } else {
                    Text("超過 \(JouleFormat.labeled(-headroom))")
                        .font(font)
                }
            }
        }
        .foregroundStyle(margin.tint ?? .secondary)
        .accessibilityElement(children: .combine)
    }
}
