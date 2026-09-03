import MuzzlemeterKit
import SwiftUI

/// 規制上限に対する段階の**見せかた**をここ 1 箇所に集める。
///
/// 色と語を画面ごとに書くと、Live では赤・履歴では橙、といった食い違いがすぐ起きる。
/// 「超過は赤」「注意は橙」を守るのは安全に直結するので、定義を分散させない。
extension EnergyMargin {
    /// 色。`.safe` は `nil`（＝その場の既定色のまま。平常時に色を付けない）。
    var tint: Color? {
        switch self {
        case .safe: nil
        case .caution: .orange
        case .over: .red
        }
    }

    /// `.safe` でも必ず色が要る場所（チャートの点など）で使う。
    var chartTint: Color {
        tint ?? .blue
    }

    /// バッジやラベルに出す短い語。
    var label: String {
        switch self {
        case .safe: String(localized: "余裕")
        case .caution: String(localized: "注意")
        case .over: String(localized: "超過")
        }
    }

    var symbolName: String {
        switch self {
        case .safe: "checkmark.circle"
        case .caution: "exclamationmark.triangle"
        case .over: "exclamationmark.octagon.fill"
        }
    }
}

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
