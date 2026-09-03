import Foundation

/// The state shown in the Live Activity (lock screen / Dynamic Island).
///
/// `ActivityKit` isn't available on macOS (`muzzlemeter-sniff` also targets macOS), so
/// `ActivityAttributes` / `ActivityAttributes.ContentState` themselves can't live here.
/// Instead, only the **pure value and calculation that decides what should currently be
/// shown** lives here, and the app's (`App/Shared/LiveActivityAttributes.swift`)
/// `ContentState` simply holds this type as-is. Because both the widget extension and the
/// app run through the same logic, the numbers on the lock screen never drift from the
/// numbers in the app.
public struct LiveActivityContent: Sendable, Hashable, Codable {
    /// The most recent shot's speed. No unit symbol; a formatted string in the display
    /// unit (m/s is already truncated the way the LCD is). `"—"` if there's no shot yet.
    public let speedText: String
    public let speedUnitSymbol: String
    /// The most recent shot's joules. `"—"` if there's no shot yet.
    public let joulesText: String
    /// The shot count. `"7 / 10"` in N-shot mode, otherwise `"12"`.
    public let shotCountText: String
    /// Mean speed (no unit symbol). `nil` for 0 shots.
    public let meanSpeedText: String?
    /// The most recent shot's stage relative to the regulation limit.
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

    /// The state before any shot has been fired (shown right after a session starts).
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

    /// Builds the display state from a list of shots. Runs through the same calculations
    /// as `ChronoService` (`SessionStats` / `EnergyLimit`), so the numbers match the
    /// app's own Live screen.
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

/// Caps how often updates go out during full-auto.
///
/// ActivityKit rate-limits Live Activity updates, and calling `update` on every shot
/// during full-auto — dozens of shots per second — causes updates to be dropped or the
/// lock screen to flicker. This holds only the decision **update only if the minimum
/// interval has passed since the last update** (built so the current time can be
/// injected, so tests can verify it without waiting on the real clock).
public struct LiveActivityUpdateThrottle: Sendable {
    /// Defaults to at most once per second (frequent enough to keep up even during
    /// full-auto, and within ActivityKit's own limit).
    public let minimumInterval: TimeInterval

    public init(minimumInterval: TimeInterval = 1.0) {
        self.minimumInterval = minimumInterval
    }

    /// Always allowed to update when there's no `lastUpdate` (i.e. it hasn't updated yet).
    public func shouldUpdate(now: Date, lastUpdate: Date?) -> Bool {
        guard let lastUpdate else { return true }
        return now.timeIntervalSince(lastUpdate) >= minimumInterval
    }
}
