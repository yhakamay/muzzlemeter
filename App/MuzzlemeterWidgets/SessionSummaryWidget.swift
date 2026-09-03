import MuzzlemeterKit
import SwiftUI
import WidgetKit

/// ホーム画面ウィジェット（small / medium）。**最新セッションのまとめだけ**を出す
/// （`docs/UX-ROADMAP.md` Round E の 10）。
///
/// タイムラインは「今」の 1 エントリだけを持つ。ウィジェットの中身は
/// セッションが終わるたびに `HomeWidgetSnapshotWriter` が書き換え、
/// `WidgetCenter.reloadTimelines` で作り直させる。時刻で自動更新する情報
/// （時計のような）ではないので、先の時刻のエントリを予測して並べる意味が無い。
///
/// 実際の見た目（`SessionSummaryWidgetView` とその中身）は
/// `App/Shared/SessionSummaryViews.swift` にあり、アプリ本体の目視確認用画面
/// （`LiveActivityPreviewHost`）とも共有している。
struct SessionSummaryEntry: TimelineEntry {
    let date: Date
    let snapshot: HomeWidgetSnapshot?
}

struct SessionSummaryProvider: TimelineProvider {
    /// ウィジェットギャラリーのプレビューに出す仮の値。
    func placeholder(in context: Context) -> SessionSummaryEntry {
        SessionSummaryEntry(date: Date(), snapshot: .previewSample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SessionSummaryEntry) -> Void) {
        completion(SessionSummaryEntry(date: Date(), snapshot: context.isPreview ? .previewSample : currentSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SessionSummaryEntry>) -> Void) {
        let entry = SessionSummaryEntry(date: Date(), snapshot: currentSnapshot())
        // `.never`: 次に変わるのは「アプリがセッションを終えて reloadTimelines を
        // 呼んだとき」だけなので、システムに時間経過での再読み込みを頼まない。
        completion(Timeline(entries: [entry], policy: .never))
    }

    private func currentSnapshot() -> HomeWidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: HomeWidgetSnapshotStore.appGroupIdentifier) else {
            return nil
        }
        return HomeWidgetSnapshotStore.load(from: defaults)
    }
}

struct SessionSummaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.sessionSummary, provider: SessionSummaryProvider()) { entry in
            SessionSummaryWidgetContainer(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(String(localized: "最新のセッション"))
        .description(String(localized: "直近に締めたセッションの発数と平均弾速を表示します。"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// `WidgetFamily`（WidgetKit）を `WidgetFamilyKind`（`App/Shared`、ウィジェット拡張に
/// 依存しない）へ変換するだけの薄い橋渡し。
private struct SessionSummaryWidgetContainer: View {
    @Environment(\.widgetFamily) private var family
    let entry: SessionSummaryEntry

    var body: some View {
        SessionSummaryWidgetView(
            family: family == .systemMedium ? .medium : .small,
            snapshot: entry.snapshot
        )
    }
}
