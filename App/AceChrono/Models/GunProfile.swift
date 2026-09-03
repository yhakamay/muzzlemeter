import Foundation
import SwiftData

/// 銃の駆動方式。ジュールの出方も、気温の効き方もこれで大きく変わるので、
/// 「あとで見返して意味がある」情報として計測に付いて回る。
///
/// 永続化は **raw な文字列**で行う。SwiftData に enum をそのまま持たせると、
/// ケースを増やしただけでストアのスキーマが変わってしまう。文字列なら
/// 未知の値を読んでも落ちず、`unknown` として扱える。
enum PowerSource: String, CaseIterable, Identifiable, Sendable {
    case electric
    case springAir
    case gasHFC134a
    case gasHFC152a
    case gasCO2
    case gasGreenGas
    case hpa

    var id: String { rawValue }

    /// 設定画面などで出す正式な名前。
    var label: String {
        switch self {
        case .electric: String(localized: "電動")
        case .springAir: String(localized: "エアコッキング")
        case .gasHFC134a: String(localized: "ガス (HFC134a)")
        case .gasHFC152a: String(localized: "ガス (HFC152a)")
        case .gasCO2: String(localized: "ガス (CO2)")
        case .gasGreenGas: String(localized: "ガス (グリーンガス)")
        case .hpa: String(localized: "HPA (エアタンク)")
        }
    }

    /// 一覧のバッジ用。行が狭いので「ガス (…)」の括弧を落とす。
    var badgeLabel: String {
        switch self {
        case .electric: String(localized: "電動")
        case .springAir: String(localized: "エアコッキング")
        case .gasHFC134a: String(localized: "HFC134a")
        case .gasHFC152a: String(localized: "HFC152a")
        case .gasCO2: String(localized: "CO2")
        case .gasGreenGas: String(localized: "グリーンガス")
        case .hpa: String(localized: "HPA")
        }
    }
}

/// 銃ごとの設定。ジュール計算に使う BB 重量と、後から見返すための仕様・メモを持つ。
@Model
final class GunProfile {
    var name: String
    /// BB 弾重量（g）。
    var bbWeightGrams: Double
    var createdAt: Date

    /// パワーソース（`PowerSource.rawValue`）。既定値があるので既存ストアはそのまま開く。
    var powerSourceRaw: String = PowerSource.electric.rawValue
    var manufacturer: String = ""
    var model: String = ""
    /// インナーバレル長（mm）。測っていない／知らないことがあるので optional。
    var innerBarrelLengthMm: Int?
    /// ホップ調整のメモ（何回転戻した、どの押しゴム、など）。
    var hopNotes: String = ""
    /// 自由記述のメモ。
    var notes: String = ""

    init(
        name: String,
        bbWeightGrams: Double = 0.25,
        createdAt: Date = Date(),
        powerSource: PowerSource = .electric,
        manufacturer: String = "",
        model: String = "",
        innerBarrelLengthMm: Int? = nil,
        hopNotes: String = "",
        notes: String = ""
    ) {
        self.name = name
        self.bbWeightGrams = bbWeightGrams
        self.createdAt = createdAt
        self.powerSourceRaw = powerSource.rawValue
        self.manufacturer = manufacturer
        self.model = model
        self.innerBarrelLengthMm = innerBarrelLengthMm
        self.hopNotes = hopNotes
        self.notes = notes
    }

    /// 保存された raw 文字列を enum で読み書きする窓口。未知の値は電動として扱う
    /// （読めない値でクラッシュさせない）。
    var powerSource: PowerSource {
        get { PowerSource(rawValue: powerSourceRaw) ?? .electric }
        set { powerSourceRaw = newValue.rawValue }
    }

    /// 「メーカー モデル」を 1 行にしたもの。どちらも空なら nil。
    var makeAndModel: String? {
        let parts = [manufacturer, model]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// 設定画面に出す BB 重量のプリセット。これ以外は自由入力。
    static let weightPresets: [Double] = [0.20, 0.25, 0.28, 0.30, 0.36, 0.40, 0.45, 0.48]

    static func weightLabel(_ grams: Double) -> String {
        String(format: "%.2f g", grams)
    }
}
