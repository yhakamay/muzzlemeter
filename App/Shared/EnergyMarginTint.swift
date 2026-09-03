import MuzzlemeterKit
import SwiftUI

/// 規制上限に対する段階の**見せかた**をここ 1 箇所に集める。
///
/// 色と語を画面ごとに書くと、Live では赤・履歴では橙、といった食い違いがすぐ起きる。
/// 「超過は赤」「注意は橙」を守るのは安全に直結するので、定義を分散させない。
///
/// **このファイルはアプリ本体（`Muzzlemeter`）とウィジェット拡張
/// （`MuzzlemeterWidgets`）の両方のターゲットに含める**（`project.yml` の
/// `App/Shared` ソースパス）。ホーム画面ウィジェットとライブアクティビティも
/// Live 画面・履歴と同じ色分けにするため（`ActivityKit` を使わない
/// Apple Watch アプリは、ここを import できない制約上、自分の小さな複製を持つ）。
extension EnergyMargin {
    /// 色。`.safe` は `nil`（＝その場の既定色のまま。平常時に色を付けない）。
    var tint: Color? {
        switch self {
        case .safe: nil
        case .caution: .orange
        case .over: .red
        }
    }

    /// `.safe` でも必ず色が要る場所（チャートの点・ウィジェットの背景など）で使う。
    var chartTint: Color {
        tint ?? .blue
    }

    /// バッジやラベルに出す短い語。
    var label: String {
        switch self {
        case .safe: String(localized: "余裕")
        case .caution: String(localized: "注意")
        case .over: String(localized: "超過")
        }
    }

    var symbolName: String {
        switch self {
        case .safe: "checkmark.circle"
        case .caution: "exclamationmark.triangle"
        case .over: "exclamationmark.octagon.fill"
        }
    }
}
