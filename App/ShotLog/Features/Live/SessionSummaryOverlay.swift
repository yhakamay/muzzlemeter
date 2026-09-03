import ShotLogKit
import SwiftUI

/// N 発モードで目標に届き、セッションが自動的に締まったときのまとめ。
///
/// **画面の上に重ねて出す**（別画面へ遷移しない）。撃ち終わった直後に見たいのは
/// 「いまの一組はどうだったか」だけで、履歴を掘りに行く操作ではない。
/// 続けて撃つなら「もう一度」で同じ条件のまま待機に戻る。
struct SessionSummaryOverlay: View {
    let summary: ChronoService.CompletedSummary
    /// 同じ条件（目標発数も含む）のまま次を待つ。
    var onRepeat: () -> Void
    /// 閉じて、目標発数を解除する（次からは手動で締める）。
    var onClose: () -> Void

    var body: some View {
        ZStack {
            // 背景を落として、まとめが最前面であることを分かるようにする。
            // タップで閉じられる（「閉じる」と同じ扱い）。
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.green)
                    Text("\(summary.targetShotCount) 発を撃ち終わりました")
                        .font(.headline)
                    Text("セッションは保存されました。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Divider()

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    alignment: .leading,
                    spacing: 12
                ) {
                    cell(StatTerm.mean.shortTitle, speed: summary.stats.meanMetersPerSecond)
                    cell(StatTerm.standardDeviation.shortTitle, speed: summary.stats.sampleStandardDeviation)
                    cell(StatTerm.extremeSpread.shortTitle, speed: summary.stats.extremeSpread)
                    maxJoulesCell
                }

                if summary.overLimitCount > 0 {
                    Label(
                        "\(summary.overLimitCount) 発が上限 \(GunProfile.energyLimitLabel(summary.energyLimitJoules)) を越えました",
                        systemImage: "exclamationmark.octagon.fill"
                    )
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 8) {
                    Button("もう一度", systemImage: "arrow.clockwise", action: onRepeat)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                    Button("閉じる", action: onClose)
                        .buttonStyle(.borderless)
                    // ボタンの違いを隠さない。「閉じる」に副作用があることを明示する。
                    Text("「もう一度」は同じ条件でもう \(summary.targetShotCount) 発。「閉じる」は目標発数を解除します。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: 340)
            .background(.background, in: .rect(cornerRadius: 20))
            .shadow(radius: 24, y: 8)
            .padding(24)
        }
        .transition(.opacity)
    }

    private func cell(_ title: String, speed: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(
                speed.map { summary.speedUnit.formatted(metersPerSecond: $0) } ?? "—"
            )
            .font(.title3.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 最大ジュールは規制上限に対する段階で色を変える（カードと同じ規則）。
    private var maxJoulesCell: some View {
        let margin = summary.stats.maxJoules.map {
            EnergyLimit.margin(joules: $0, limitJoules: summary.energyLimitJoules)
        } ?? .safe
        return VStack(alignment: .leading, spacing: 2) {
            Text("最大 J")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(summary.stats.maxJoules.map(JouleFormat.labeled) ?? "—")
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(margin.tint ?? .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
