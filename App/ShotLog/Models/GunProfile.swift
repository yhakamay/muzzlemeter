import Foundation
import SwiftData

/// 銃の駆動方式の**区分**。
///
/// 以前は「ガス (HFC134a)」のようにガス種別まで含んだ 1 つの列挙だったが、ガス種別は
/// **その日その回の条件**（何を詰めて撃ったか）であって銃そのものの属性ではない。
/// 区分だけを銃に残し、ガス種別はセッション変数へ移した（`docs/UX-ROADMAP.md` Round A）。
///
/// 永続化は **raw な文字列**で行う。SwiftData に enum をそのまま持たせると、
/// ケースを増やしただけでストアのスキーマが変わってしまう。文字列なら
/// 未知の値を読んでも落ちず、既定値として扱える。
enum PowerCategory: String, CaseIterable, Identifiable, Sendable {
    case electric
    case gas
    case springAir
    case hpa

    var id: String { rawValue }

    /// 設定画面などで出す正式な名前。
    var label: String {
        switch self {
        case .electric: String(localized: "電動")
        case .gas: String(localized: "ガス")
        case .springAir: String(localized: "エアコッキング")
        case .hpa: String(localized: "HPA (エアタンク)")
        }
    }

    /// 一覧のバッジ用。行が狭いので括弧書きを落とす。
    var badgeLabel: String {
        switch self {
        case .electric: String(localized: "電動")
        case .gas: String(localized: "ガス")
        case .springAir: String(localized: "エアコッキング")
        case .hpa: String(localized: "HPA")
        }
    }

    /// ガス種別を訊く意味があるか。
    var usesGas: Bool { self == .gas }
}

/// ガス種別。区分がガスのときだけ意味を持つ。
///
/// 銃ではなく**セッション**の条件。同じ銃でも冬は 152a、夏は 134a、という使い分けを
/// そのまま記録できるようにするため。
enum GasType: String, CaseIterable, Identifiable, Sendable {
    case hfc134a
    case hfc152a
    case co2
    case greenGas
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hfc134a: String(localized: "HFC134a")
        case .hfc152a: String(localized: "HFC152a")
        case .co2: String(localized: "CO2")
        case .greenGas: String(localized: "グリーンガス")
        case .other: String(localized: "その他")
        }
    }
}

/// 銃ごとの設定。**銃そのものの属性**と、**セッション変数の既定値**を持つ。
///
/// 「その回ごとに変わるもの」（BB 重量・ガス種別・ホップ）はセッション側が本体で、
/// ここにあるのは新しいセッションを始めるときの初期値。
@Model
final class GunProfile {
    var name: String
    /// BB 弾重量（g）の既定値。**列名は旧スキーマのまま**にしてある（`defaultBBWeightGrams` を参照）。
    var bbWeightGrams: Double
    var createdAt: Date

    /// 旧スキーマの「パワーソース」（区分とガス種別が混ざっていた）。
    /// 移行元としてだけ残してある。新しいコードは読み書きしない。既定値も変えない
    /// （既定値を変えると新規ストアの列定義が動くので、互換のため触らない）。
    var powerSourceRaw: String = "electric"

    /// パワーソース区分（`PowerCategory.rawValue`）。空文字は「まだ移行していない」。
    var powerCategoryRaw: String = ""
    /// ガス種別の既定値（`GasType.rawValue`）。区分がガスのときだけ意味を持つ。
    var defaultGasTypeRaw: String = GasType.hfc134a.rawValue
    /// 規制上限（J）。日本の法令上限 0.98 J が既定だが、フィールド独自の上限
    /// （0.9 J など）を入れられるようにプロファイルごとに変更できる。
    var energyLimitJoules: Double = 0.98

    var manufacturer: String = ""
    var model: String = ""
    /// インナーバレル長（mm）。測っていない／知らないことがあるので optional。
    var innerBarrelLengthMm: Int?
    /// ホップ設定の既定値。**列名は旧スキーマのまま**（`defaultHopSetting` を参照）。
    /// 自由記述にしてあるのは、目盛りの単位が銃ごとに違うから（「3」「少し強め」など）。
    var hopNotes: String = ""
    /// 目標発数の既定値（N 発モード）。`nil` は「手動で締める」。
    ///
    /// 「この銃はいつも 10 発で見る」のような癖は銃ごとに決まっているので、
    /// 既定値はプロファイルが持ち、その回だけ変えたいときはセッション条件で上書きする。
    var targetShotCount: Int?
    /// 自由記述のメモ。
    var notes: String = ""

    init(
        name: String,
        bbWeightGrams: Double = 0.25,
        createdAt: Date = Date(),
        powerCategory: PowerCategory = .electric,
        defaultGasType: GasType = .hfc134a,
        defaultHopSetting: String = "",
        energyLimitJoules: Double = 0.98,
        manufacturer: String = "",
        model: String = "",
        innerBarrelLengthMm: Int? = nil,
        targetShotCount: Int? = nil,
        notes: String = ""
    ) {
        self.name = name
        self.bbWeightGrams = bbWeightGrams
        self.createdAt = createdAt
        self.powerCategoryRaw = powerCategory.rawValue
        self.defaultGasTypeRaw = defaultGasType.rawValue
        self.energyLimitJoules = energyLimitJoules
        self.manufacturer = manufacturer
        self.model = model
        self.innerBarrelLengthMm = innerBarrelLengthMm
        self.targetShotCount = targetShotCount
        self.hopNotes = defaultHopSetting
        self.notes = notes
    }

    // MARK: - 列名の別名
    //
    // `bbWeightGrams` / `hopNotes` は**意味が「既定値」に変わった**が、列名は変えていない。
    // SwiftData で列名を変えると軽量マイグレーションでは済まなくなり、実機に入っている
    // ストアを開けなくなる危険がある。呼ぶ側の名前だけ新しくして、保存先は据え置く。

    /// BB 重量の既定値（g）。
    var defaultBBWeightGrams: Double {
        get { bbWeightGrams }
        set { bbWeightGrams = newValue }
    }

    /// ホップ設定の既定値。
    var defaultHopSetting: String {
        get { hopNotes }
        set { hopNotes = newValue }
    }

    /// 保存された raw 文字列を enum で読み書きする窓口。未知の値は電動として扱う
    /// （読めない値でクラッシュさせない）。
    var powerCategory: PowerCategory {
        get { PowerCategory(rawValue: powerCategoryRaw) ?? .electric }
        set { powerCategoryRaw = newValue.rawValue }
    }

    var defaultGasType: GasType {
        get { GasType(rawValue: defaultGasTypeRaw) ?? .hfc134a }
        set { defaultGasTypeRaw = newValue.rawValue }
    }

    /// 新しいセッションが始まるときの初期値一式。
    var defaultVariables: SessionVariables {
        SessionVariables(
            bbWeightGrams: defaultBBWeightGrams,
            gasType: defaultGasType,
            hopSetting: defaultHopSetting,
            targetShotCount: targetShotCount
        )
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

    /// 規制上限の表示（`0.98 J`）。
    static func energyLimitLabel(_ joules: Double) -> String {
        JouleFormat.labeled(joules)
    }
}
