import MuzzlemeterKit
import SwiftUI

/// ロック画面 / Dynamic Island の**目視確認用**画面。
///
/// シミュレータには「ロックする」を自動操作する手段が無い（`xcrun simctl` にロック
/// 相当の操作が無く、タップ操作はスクリーンショットの手順からは行えない）。実際に
/// ロック画面・Dynamic Island で使う View は `App/Shared/LiveActivityViews.swift` に
/// 置いてあり、ここは**同じ View をアプリの画面の中に並べて出すだけ**。別実装ではなく
/// 本物と同じコードなので、レイアウト・配色・切り捨て（LCD 風の表示）はそのまま確認できる。
/// システム標準の縁取り・角丸のクロームまでは再現しない（そこは OS が描く部分）。
///
/// `--demo-widgets` でだけ開く（`ScreenshotSupport.opensWidgetPreview`）。
struct LiveActivityPreviewHost: View {
    @Environment(ChronoService.self) private var service
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section(title: String(localized: "ロック画面 / Dynamic Island（見本）")) {
                        VStack(spacing: 12) {
                            LockScreenLiveActivityView(state: activityContent)
                                .padding()
                                .background(.black, in: .rect(cornerRadius: 24))
                            HStack(spacing: 8) {
                                // compact
                                HStack(spacing: 6) {
                                    Image(systemName: "scope")
                                        .foregroundStyle(activityContent.margin.tint ?? .white)
                                    SpeedText(state: activityContent, font: .caption.monospacedDigit())
                                        .foregroundStyle(.white)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.black, in: .capsule)
                                Text("compact")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(activityContent.gunName)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Text(activityContent.shotCountText)
                                            .font(.headline)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        SpeedText(state: activityContent, font: .title2.weight(.bold))
                                        Text(String(localized: "\(activityContent.joulesText) J"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                ExpandedBottomRow(state: activityContent)
                            }
                            .padding()
                            .foregroundStyle(.white)
                            .background(.black, in: .rect(cornerRadius: 24))
                            Text("expanded")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(Text(verbatim: "Live Activity"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "閉じる")) { dismiss() }
                }
            }
        }
    }

    private func section(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    /// いま計測中ならその値、無ければ待機表示。
    private var activityContent: LiveActivityContent {
        LiveActivityContent.derive(
            shots: service.currentShots,
            massGrams: service.massGrams,
            speedUnit: service.speedUnit,
            energyLimitJoules: service.energyLimitJoules,
            target: service.shotTarget,
            gunName: service.gunName
        )
    }
}

#Preview {
    LiveActivityPreviewHost()
        .environment(ChronoService(defaults: PreviewSupport.defaults, forceReplay: true))
}
