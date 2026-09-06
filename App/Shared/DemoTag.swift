import SwiftUI

/// デモモードの印。**アプリ本体とウィジェット拡張の両方に含める**
/// （`project.yml` の `App/Shared`）。
///
/// このアプリは「その銃がフィールドの規制上限に収まっているか」を確かめるために
/// 使われる。合成した弾速が実測に見えてしまうのは紛らわしさではなく危険なので、
/// 印は Live 画面・履歴・ロック画面・ホーム画面ウィジェットのどこでも**同じ形**で
/// 出さなければならない。見た目を画面ごとに書くと、いつか 1 か所だけ抜ける。
enum DemoMarkerStyle {
    /// デモの印の色。規制上限の意味で使っている緑・橙・赤とは重ならない色にする
    /// （「デモ」と「上限に近い」を色で取り違えさせない）。
    static let tint = Color.purple
}

/// 「DEMO」の小さなラベル。行や見出しに添える。
///
/// 文字は **翻訳しない**（`Text(verbatim:)`）。`DEMO` はどの言語でも読める短い印で、
/// 訳し分けると「同じ印」に見えなくなる。意味の説明は隣の文で出す。
struct DemoBadge: View {
    /// ロック画面・ウィジェットのように背景が読めない場所では、色ではなく
    /// 縁取りで浮かせる。
    var isProminent = false

    var body: some View {
        Text(verbatim: "DEMO")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                isProminent ? AnyShapeStyle(.thinMaterial)
                    : AnyShapeStyle(DemoMarkerStyle.tint.opacity(0.18)),
                in: .capsule
            )
            .foregroundStyle(DemoMarkerStyle.tint)
            .accessibilityLabel(Text("デモモードの記録"))
    }
}
