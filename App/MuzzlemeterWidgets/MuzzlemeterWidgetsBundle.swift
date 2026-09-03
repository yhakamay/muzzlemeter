import SwiftUI
import WidgetKit

/// ウィジェット拡張のエントリポイント。1 つの拡張ターゲットに複数の `Widget` を
/// まとめられるので、ここへ順次登録していく（次はホーム画面ウィジェット）。
@main
struct MuzzlemeterWidgetsBundle: WidgetBundle {
    var body: some Widget {
        MuzzlemeterLiveActivityWidget()
    }
}
