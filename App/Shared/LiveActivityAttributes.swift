import ActivityKit
import Foundation
import MuzzlemeterKit

/// ライブアクティビティ（ロック画面 / Dynamic Island）の固定属性。
///
/// **このファイルはアプリ本体（`Muzzlemeter`）とウィジェット拡張
/// （`MuzzlemeterWidgets`）の両方のターゲットに含める**（`project.yml` の
/// `App/Shared` ソースパス）。両者が同じ `ActivityAttributes` 型を見ていないと
/// `Activity<MuzzlemeterLiveActivityAttributes>` の型が一致せず、拡張側の
/// `ActivityConfiguration` がアプリの起動したアクティビティを描画できない。
///
/// `ActivityKit` は macOS では使えないため、`MuzzlemeterKit`（macOS の CLI も
/// ビルド対象）にはこの型を置けない。中身の表示ロジック（`ContentState` が
/// 何を持つか、どう計算するか）だけを `MuzzlemeterKit.LiveActivityContent` に
/// 追い出し、ここには ActivityKit が要求する骨組みだけを置く。
struct MuzzlemeterLiveActivityAttributes: ActivityAttributes {
    typealias ContentState = LiveActivityContent

    /// セッション開始時刻。`ContentState` に入れないのは、Dynamic Island の
    /// 経過時間表示のように「アクティビティを通じて変わらない値」として
    /// 扱わせたいため（毎回のショットで書き換える対象ではない）。
    let startedAt: Date
}
