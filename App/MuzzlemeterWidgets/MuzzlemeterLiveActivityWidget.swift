import ActivityKit
import MuzzlemeterKit
import SwiftUI
import WidgetKit

/// ロック画面 / Dynamic Island のライブアクティビティ（`docs/UX-ROADMAP.md` Round E の 4）。
///
/// 表示する値は `MuzzlemeterKit.LiveActivityContent`（`ChronoService` が計算して
/// `LiveActivityService` 経由で渡す）をそのまま使う。中身の View
/// （`LockScreenLiveActivityView` など）は `App/Shared/LiveActivityViews.swift`
/// に置いてあり、アプリ本体の目視確認用画面（`LiveActivityPreviewHost`）とも共有する。
struct MuzzlemeterLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MuzzlemeterLiveActivityAttributes.self) { context in
            LockScreenLiveActivityView(state: context.state)
                .activityBackgroundTint(.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.gunName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(context.state.shotCountText)
                            .font(.headline)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        SpeedText(state: context.state, font: .title2.weight(.bold))
                        Text(String(localized: "\(context.state.joulesText) J"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottomRow(state: context.state)
                }
            } compactLeading: {
                Image(systemName: "scope")
                    .foregroundStyle(context.state.margin.tint ?? .primary)
            } compactTrailing: {
                SpeedText(state: context.state, font: .caption.monospacedDigit())
            } minimal: {
                Image(systemName: "scope")
                    .foregroundStyle(context.state.margin.tint ?? .primary)
            }
            .keylineTint(context.state.margin.chartTint)
        }
    }
}
