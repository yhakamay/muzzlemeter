import MuzzlemeterKit
import SwiftUI

/// 規制上限に対する段階の色。iPhone 側 / ウィジェット側は `App/Shared/EnergyMarginTint.swift`
/// を使うが、その実装は `ActivityKit` を import する `LiveActivityAttributes.swift` と
/// 同じフォルダを共有しているため、`ActivityKit` の無い watchOS ターゲットには
/// フォルダごと足せない。**色の対応だけの小さな複製**をここに持つ
/// （`EnergyMargin.label` / `symbolName` は文字列・シンボル名なのでキット側で足りるが、
/// `Color` は SwiftUI 依存でキットに置けないので、こことアプリ側の 2 箇所になる）。
extension EnergyMargin {
    var tint: Color? {
        switch self {
        case .safe: nil
        case .caution: .orange
        case .over: .red
        }
    }
}
