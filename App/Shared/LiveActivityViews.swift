import MuzzlemeterKit
import SwiftUI

/// ライブアクティビティの見た目（ロック画面 / Dynamic Island で使う部品）。
///
/// **このファイルはアプリ本体（`Muzzlemeter`）とウィジェット拡張
/// （`MuzzlemeterWidgets`）の両方のターゲットに含める**（`project.yml` の
/// `App/Shared`）。ウィジェット拡張側は `MuzzlemeterLiveActivityWidget`
/// （`ActivityConfiguration`）からそのまま使う。アプリ側は、実機の
/// シミュレータではロック画面 / Dynamic Island を自動操作で開けない
/// （`xcrun simctl` にロック相当の操作が無い）ため、**同じ View を
/// 目視確認用の画面（`LiveActivityPreviewHost`）から直接インスタンス化**して
/// 見た目を確かめる。別実装を用意すると「本物と同じに見えるだけの偽物」に
/// なってしまうので、必ずこの 1 つを両方から使う。
struct LockScreenLiveActivityView: View {
    let state: LiveActivityContent

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.gunName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                SpeedText(state: state, font: .system(size: 40, weight: .bold, design: .rounded))
                HStack(spacing: 8) {
                    Label(String(localized: "\(state.joulesText) J"), systemImage: "bolt.fill")
                    Text(state.shotCountText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            MarginBadge(margin: state.margin)
        }
        .padding()
        .foregroundStyle(.white)
    }
}

/// Dynamic Island 展開時の下段。
struct ExpandedBottomRow: View {
    let state: LiveActivityContent

    var body: some View {
        HStack {
            if let mean = state.meanSpeedText {
                Label(String(localized: "平均 \(mean) \(state.speedUnitSymbol)"), systemImage: "chart.bar.fill")
                    .font(.caption)
            }
            Spacer()
            MarginBadge(margin: state.margin)
        }
    }
}

/// 直近 1 発の速度。`—` のときは単位記号を出さない（値が無いのに単位だけ出ると
/// 何かの読み違いに見えるため）。
struct SpeedText: View {
    let state: LiveActivityContent
    var font: Font

    var body: some View {
        if state.speedText == "—" {
            Text(state.speedText).font(font)
        } else {
            (Text(state.speedText).font(font)
                + Text(" \(state.speedUnitSymbol)").font(.caption).foregroundStyle(.secondary))
        }
    }
}

struct MarginBadge: View {
    let margin: EnergyMargin

    var body: some View {
        Label(margin.label, systemImage: margin.symbolName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(margin.tint ?? .secondary)
            .labelStyle(.titleAndIcon)
    }
}
