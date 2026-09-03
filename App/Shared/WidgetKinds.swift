import Foundation

/// ウィジェット拡張の kind 文字列。アプリ側（`WidgetCenter.reloadTimelines(ofKind:)`）と
/// ウィジェット側（`Widget.kind`）で綴りがずれるとリロードが効かなくなるので、
/// 両ターゲットに含まれるここ 1 箇所に置く（`project.yml` の `App/Shared`）。
enum WidgetKinds {
    static let sessionSummary = "MuzzlemeterSessionSummaryWidget"
}
