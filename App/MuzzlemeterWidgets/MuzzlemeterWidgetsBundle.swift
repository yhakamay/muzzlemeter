import SwiftUI
import WidgetKit

/// ウィジェット拡張のエントリポイント（@main WidgetBundle）。
@main
struct MuzzlemeterWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SessionSummaryWidget()
        MuzzlemeterLiveActivityWidget()
    }
}
