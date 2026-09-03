import Foundation

/// ライブアクティビティ（ロック画面 / Dynamic Island）に出す状態。
///
/// `ActivityKit` は macOS では使えない（`muzzlemeter-sniff` は macOS もビルド対象）ので、
/// `ActivityAttributes` / `ActivityAttributes.ContentState` そのものはここには置けない。
/// 代わりに **「いま何を表示すべきか」を決める純粋な値と計算**だけをここへ置き、
/// アプリ（`App/Shared/LiveActivityAttributes.swift`）側の `ContentState` が
/// この型をそのまま持つ。ウィジェット拡張とアプリ本体の両方が同じロジックを通ることで、
/// ロック画面の数字とアプリ内の数字がずれない。
public struct LiveActivityContent: Sendable, Hashable, Codable {
    /// 直近 1 発の速度。単位記号なし、表示単位の整形済み文字列（m/s は LCD 風に切り捨て済み）。
    /// まだ 1 発も無ければ `"—"`。
    public let speedText: String
    public let speedUnitSymbol: String
    /// 直近 1 発のジュール。まだ 1 発も無ければ `"—"`。
    public let joulesText: String
    /// 発数。N 発モードなら `"7 / 10"`、それ以外は `"12"`。
    public let shotCountText: String
    /// 平均速度（単位記号なし）。0 発なら `nil`。
    public let meanSpeedText: String?
    /// 直近 1 発の規制上限に対する段階。
    public let margin: EnergyMargin
    public let gunName: String

    public init(
        speedText: String,
        speedUnitSymbol: String,
        joulesText: String,
        shotCountText: String,
        meanSpeedText: String?,
        margin: EnergyMargin,
        gunName: String
    ) {
        self.speedText = speedText
        self.speedUnitSymbol = speedUnitSymbol
        self.joulesText = joulesText
        self.shotCountText = shotCountText
        self.meanSpeedText = meanSpeedText
        self.margin = margin
        self.gunName = gunName
    }

    /// 1 発も撃っていない状態（セッション開始直後の表示）。
    public static func idle(gunName: String, speedUnit: SpeedUnit) -> LiveActivityContent {
        LiveActivityContent(
            speedText: "—",
            speedUnitSymbol: speedUnit.symbol,
            joulesText: "—",
            shotCountText: "0",
            meanSpeedText: nil,
            margin: .safe,
            gunName: gunName
        )
    }

    /// ショット列から表示状態を作る。`ChronoService` と同じ計算（`SessionStats` /
    /// `EnergyLimit`）を通すので、アプリ本体の Live 画面と数字が一致する。
    public static func derive(
        shots: [Shot],
        massGrams: Double,
        speedUnit: SpeedUnit,
        energyLimitJoules: Double,
        target: ShotTarget?,
        gunName: String
    ) -> LiveActivityContent {
        guard let last = shots.last else { return .idle(gunName: gunName, speedUnit: speedUnit) }
        let stats = SessionStats.compute(shots: shots, massGrams: massGrams)
        let margin = EnergyLimit.margin(
            massGrams: massGrams,
            velocityMetersPerSecond: last.velocityMetersPerSecond,
            limitJoules: energyLimitJoules
        )
        let shotCountText = target.map { "\(shots.count) / \($0.count)" } ?? "\(shots.count)"
        return LiveActivityContent(
            speedText: speedUnit.format(metersPerSecond: last.velocityMetersPerSecond),
            speedUnitSymbol: speedUnit.symbol,
            joulesText: JouleFormat.value(last.joules(massGrams: massGrams)),
            shotCountText: shotCountText,
            meanSpeedText: stats.meanMetersPerSecond.map { speedUnit.format(metersPerSecond: $0) },
            margin: margin,
            gunName: gunName
        )
    }
}

/// フルオートでの更新頻度を抑える。
///
/// Live Activity の更新には ActivityKit 側のレート制限があり、1 秒間に何十発も来る
/// フルオートでショットのたびに `update` を呼ぶと更新が捨てられたり、ロック画面が
/// ちらつく。**直近の更新から最小間隔が経っているときだけ更新する**、という判定だけを
/// ここに置く（日時を注入できる形にして、テストでは実時計を待たずに確かめる）。
public struct LiveActivityUpdateThrottle: Sendable {
    /// 既定は 1 秒に 1 回まで（フルオートでも十分追える頻度で、ActivityKit の制限にも収まる）。
    public let minimumInterval: TimeInterval

    public init(minimumInterval: TimeInterval = 1.0) {
        self.minimumInterval = minimumInterval
    }

    /// `lastUpdate` が無い（まだ 1 回も更新していない）ときは常に更新してよい。
    public func shouldUpdate(now: Date, lastUpdate: Date?) -> Bool {
        guard let lastUpdate else { return true }
        return now.timeIntervalSince(lastUpdate) >= minimumInterval
    }
}
