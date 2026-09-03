import MuzzlemeterKit
import Foundation
import SwiftData

/// 1 回の計測セッション。最初の 1 発で自動的に作られる。
///
/// 銃名と BB 重量は `GunProfile` への参照ではなく**値としてコピーして持つ**。
/// 後からプロファイルの重量を変えても、過去のセッションのジュールが変わってしまわないため。
@Model
final class Session {
    var startedAt: Date
    var endedAt: Date?
    /// ユーザーが付けた名前。`nil`（または空）なら日時＋銃名の自動タイトルを使う。
    ///
    /// 自動タイトルを「保存された文字列」にしてしまうと、後から銃名を直したときに
    /// 過去のセッション名が食い違う。付けられた名前だけを持ち、無いときは都度組み立てる。
    var title: String?
    /// 計測時の銃プロファイル名（スナップショット）。
    var gunName: String

    // MARK: - セッション変数（その回の条件）
    //
    // プロファイルの既定値を**開始時にコピー**したもの。あとから変えられ、変えれば
    // このセッション全体のジュールが計算し直される（`SessionVariables` のコメント参照）。

    /// 計測時の BB 重量（g）。
    var bbWeightGrams: Double
    /// 計測時のガス種別（`GasType.rawValue`）。区分がガスのときだけ意味を持つ。
    var gasTypeRaw: String = GasType.hfc134a.rawValue
    /// 計測時のホップ設定（自由記述）。空文字は「記録なし」。
    var hopSetting: String = ""
    /// 目標発数（N 発モード）。`nil` は「手動で締める」。
    /// **どのセッションが N 発モードだったか**は後から見て意味があるので記録する。
    var targetShotCount: Int?
    /// タグ。改行区切りの 1 列で持つ（絞り込み UI は Round C）。
    ///
    /// `[String]` を transformable にすると述語で扱えず、別モデルにするとテーブルが
    /// 増える。件数が高々数個なので、**文字列 1 列**で足りる。
    var tagsRaw: String = ""

    // 銃の仕様も**値としてコピー**する（`GunProfile` を参照しない）。
    // 銃名・BB 重量と同じ理由で、後からプロファイルを直しても過去の計測の
    // 記録が書き換わってはいけない。既定値付きなのでライトウェイトマイグレーション。

    /// 旧スキーマの「パワーソース」（区分とガス種別が混ざっていた）。移行元としてだけ残す。
    var gunPowerSourceRaw: String = ""
    /// 計測時のパワーソース区分（`PowerCategory.rawValue`）。空文字は「記録なし」。
    var gunPowerCategoryRaw: String = ""
    /// 計測時に適用していた規制上限（J）。あとからプロファイルの上限を変えても、
    /// 「そのときは何 J までのつもりで撃っていたか」は変わってはいけない。
    var energyLimitJoules: Double = 0.98
    var gunManufacturer: String = ""
    var gunModel: String = ""
    var gunInnerBarrelLengthMm: Int?

    // MARK: - 環境（自動取得）
    //
    // WeatherKit と CoreLocation から**セッション開始時に一度だけ**取る。
    // 取れなかった場合（未許可・オフライン・エンタイトルメント未反映）は
    // すべて nil のままにする。「取れなかった」と「0 だった」を区別するため。

    var autoTemperatureC: Double?
    /// 相対湿度。WeatherKit と同じ 0–1 で持つ（表示のときだけ % にする）。
    var autoHumidity: Double?
    var autoPressureHPa: Double?
    /// 天気の SF Symbol 名（WeatherKit の `symbolName`）。
    var autoConditionSymbol: String?
    /// 天気の説明文（WeatherKit が返すローカライズ済みの文字列）。
    var autoConditionText: String?
    /// 逆ジオコーディングした地名。取れなくても計測には影響しないので best effort。
    var placeName: String?
    var latitude: Double?
    var longitude: Double?
    var weatherFetchedAt: Date?

    // MARK: - 環境（手動の上書き）
    //
    // 自動値を**書き換えず別の列に持つ**。上書きしてしまうと「元の観測値は何だったか」
    // が失われ、手動値を消しても自動値に戻せない。実効値は manual ?? auto。

    var manualTemperatureC: Double?
    var manualHumidity: Double?
    var manualPressureHPa: Double?
    /// 屋内 / 屋外、風の有無など、数値にならない条件。
    var manualNotes: String?

    @Relationship(deleteRule: .cascade, inverse: \ShotRecord.session)
    var shots: [ShotRecord] = []

    init(
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        title: String? = nil,
        gunName: String,
        variables: SessionVariables = SessionVariables(),
        gunPowerCategory: PowerCategory? = nil,
        energyLimitJoules: Double = 0.98,
        gunManufacturer: String = "",
        gunModel: String = "",
        gunInnerBarrelLengthMm: Int? = nil
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.gunName = gunName
        let variables = variables.normalized
        self.bbWeightGrams = variables.bbWeightGrams
        self.gasTypeRaw = variables.gasType.rawValue
        self.hopSetting = variables.hopSetting
        self.targetShotCount = variables.targetShotCount
        self.gunPowerCategoryRaw = gunPowerCategory?.rawValue ?? ""
        self.energyLimitJoules = energyLimitJoules
        self.gunManufacturer = gunManufacturer
        self.gunModel = gunModel
        self.gunInnerBarrelLengthMm = gunInnerBarrelLengthMm
    }

    /// 記録されているパワーソース区分。古いセッション（列が無かった頃）は nil。
    var gunPowerCategory: PowerCategory? {
        PowerCategory(rawValue: gunPowerCategoryRaw)
    }

    /// 記録されているガス種別。区分がガスでなければ nil（出しても意味が無い）。
    var gasType: GasType? {
        guard gunPowerCategory?.usesGas == true else { return nil }
        return GasType(rawValue: gasTypeRaw)
    }

    // MARK: - セッション変数

    /// その回の計測条件。書き込むと BB 重量が変わり、統計・ジュールが計算し直される。
    var variables: SessionVariables {
        get {
            SessionVariables(
                bbWeightGrams: bbWeightGrams,
                gasType: GasType(rawValue: gasTypeRaw) ?? .hfc134a,
                hopSetting: hopSetting,
                targetShotCount: targetShotCount
            )
        }
        set {
            let normalized = newValue.normalized
            bbWeightGrams = normalized.bbWeightGrams
            gasTypeRaw = normalized.gasType.rawValue
            hopSetting = normalized.hopSetting
            targetShotCount = normalized.targetShotCount
        }
    }

    /// 詳細画面などに出す 1 行（`0.25 g · HFC134a · ホップ 3`）。
    var variablesSummary: String {
        variables.summary(category: gunPowerCategory ?? .electric)
    }

    /// タグ。改行区切りの 1 列を配列として読み書きする窓口。
    var tags: [String] {
        get {
            tagsRaw.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set {
            tagsRaw = newValue
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    /// 「メーカー モデル」を 1 行にしたもの。どちらも空なら nil。
    var gunMakeAndModel: String? {
        let parts = [gunManufacturer, gunModel]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: - 環境の実効値

    /// 実効気温（℃）。手動で入れた値があればそちら。
    var temperatureC: Double? { manualTemperatureC ?? autoTemperatureC }
    /// 実効湿度（0–1）。
    var humidity: Double? { manualHumidity ?? autoHumidity }
    /// 実効気圧（hPa）。
    var pressureHPa: Double? { manualPressureHPa ?? autoPressureHPa }

    var isTemperatureManual: Bool { manualTemperatureC != nil }
    var isHumidityManual: Bool { manualHumidity != nil }
    var isPressureManual: Bool { manualPressureHPa != nil }

    /// WeatherKit から何か取れているか（Apple Weather の表記を出す条件）。
    var hasAutoWeather: Bool {
        autoTemperatureC != nil || autoHumidity != nil || autoPressureHPa != nil
            || autoConditionText != nil
    }

    /// 環境セクションに出すものが 1 つでもあるか。
    var hasEnvironmentData: Bool {
        temperatureC != nil || humidity != nil || pressureHPa != nil
            || autoConditionText != nil || placeName != nil
            || !(manualNotes?.isEmpty ?? true)
    }

    /// 手動の上書きをすべて消して自動値に戻す。
    func resetManualEnvironment() {
        manualTemperatureC = nil
        manualHumidity = nil
        manualPressureHPa = nil
        manualNotes = nil
    }

    // MARK: - 名前

    /// 名前が付いていないときに使う自動タイトル（日時 + 銃名）。
    var autoTitle: String {
        let date = startedAt.formatted(.dateTime.month().day().hour().minute())
        let gun = gunName.trimmingCharacters(in: .whitespacesAndNewlines)
        return gun.isEmpty ? date : "\(date)  \(gun)"
    }

    /// 画面にも CSV にも出す実効タイトル。名前があればそれ、無ければ自動タイトル。
    var displayTitle: String {
        customTitle ?? autoTitle
    }

    /// 空白だけの名前は「名前なし」として扱う（アラートで全消ししたら自動タイトルに戻る）。
    var customTitle: String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var hasCustomTitle: Bool { customTitle != nil }

    /// 名前を設定する。空文字なら自動タイトルへ戻す。
    func setTitle(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        title = trimmed.isEmpty ? nil : trimmed
    }

    /// 時刻順のショット。SwiftData のリレーションは順序を保証しないので毎回並べ替える。
    var orderedShots: [ShotRecord] {
        shots.sorted { $0.timestamp < $1.timestamp }
    }

    var domainShots: [Shot] {
        orderedShots.map(\.asShot)
    }

    var stats: SessionStats {
        SessionStats.compute(shots: domainShots, massGrams: bbWeightGrams)
    }

    var isActive: Bool { endedAt == nil }
}
