import Foundation
import SwiftData

/// 銃ごとの設定。ジュール計算に使う BB 重量を持つ。
@Model
final class GunProfile {
    var name: String
    /// BB 弾重量（g）。
    var bbWeightGrams: Double
    var createdAt: Date

    init(name: String, bbWeightGrams: Double = 0.25, createdAt: Date = Date()) {
        self.name = name
        self.bbWeightGrams = bbWeightGrams
        self.createdAt = createdAt
    }

    /// 設定画面に出す BB 重量のプリセット。これ以外は自由入力。
    static let weightPresets: [Double] = [0.20, 0.25, 0.28, 0.30, 0.36, 0.40, 0.45, 0.48]

    static func weightLabel(_ grams: Double) -> String {
        String(format: "%.2f g", grams)
    }
}
