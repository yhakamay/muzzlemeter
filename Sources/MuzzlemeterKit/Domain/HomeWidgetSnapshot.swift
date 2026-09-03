import Foundation

/// ホーム画面ウィジェットに出す「最新セッションのまとめ」。
///
/// ウィジェット拡張は**アプリと別プロセス**で動くので、SwiftData のストアへ直接は
/// 触れない（触れても App Group 越しに開けはするが、スキーマ変更のたびに拡張側も
/// 追随させるのは重い）。代わりに、アプリがセッションを終えるたびに**この値だけ**を
/// App Group 共有の `UserDefaults` へ書き、ウィジェットはそれを読むだけにする
/// （詳しい比較は当該コミットの ADR 参照）。
public struct HomeWidgetSnapshot: Sendable, Hashable, Codable {
    public let title: String
    public let gunName: String
    public let shotCount: Int
    /// 平均速度（m/s）。0 発のセッションは無い想定だが、念のため optional。
    public let meanSpeedMetersPerSecond: Double?
    public let meanJoules: Double?
    public let overLimitCount: Int
    public let endedAt: Date
    public let speedUnit: SpeedUnit

    public init(
        title: String,
        gunName: String,
        shotCount: Int,
        meanSpeedMetersPerSecond: Double?,
        meanJoules: Double?,
        overLimitCount: Int,
        endedAt: Date,
        speedUnit: SpeedUnit
    ) {
        self.title = title
        self.gunName = gunName
        self.shotCount = shotCount
        self.meanSpeedMetersPerSecond = meanSpeedMetersPerSecond
        self.meanJoules = meanJoules
        self.overLimitCount = overLimitCount
        self.endedAt = endedAt
        self.speedUnit = speedUnit
    }

    /// 単位記号付きの平均速度。0 発なら `nil`。
    public var formattedMeanSpeed: String? {
        meanSpeedMetersPerSecond.map { speedUnit.formatted(metersPerSecond: $0) }
    }

    /// `1.03 J` のように整形した平均ジュール。
    public var formattedMeanJoules: String? {
        meanJoules.map { JouleFormat.labeled($0) }
    }
}

/// `HomeWidgetSnapshot` を App Group 共有の `UserDefaults` へ出し入れする窓口。
///
/// アプリ本体の他の設定（`ChronoService.Keys` など）と同じキー・バリュー方式に揃え、
/// JSON ファイルは使わない（App Group コンテナのファイル I/O よりも、既に使っている
/// `UserDefaults(suiteName:)` のほうがテストで注入しやすく、キーの衝突も避けやすい）。
public enum HomeWidgetSnapshotStore {
    /// アプリ・ウィジェット拡張の両方で `project.yml` の entitlements に登録してある App Group。
    public static let appGroupIdentifier = "group.com.yhakamay.muzzlemeter"

    private static let key = "muzzlemeter.homeWidgetSnapshot"

    /// 保存する。既存の値は上書きする（常に「最新のセッション」だけを持つ）。
    public static func save(_ snapshot: HomeWidgetSnapshot, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    /// 読み出す。まだ 1 回もセッションを終えていなければ `nil`。
    public static func load(from defaults: UserDefaults) -> HomeWidgetSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HomeWidgetSnapshot.self, from: data)
    }
}
