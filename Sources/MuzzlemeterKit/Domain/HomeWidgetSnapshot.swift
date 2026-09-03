import Foundation

/// The "latest session summary" shown on the Home Screen widget.
///
/// The widget extension runs in **a separate process from the app**, so it can't touch
/// the SwiftData store directly (it could reach it through the App Group, but making the
/// extension track every schema change too would be heavy). Instead, every time the app
/// ends a session it writes **just this value** to an App Group-shared `UserDefaults`,
/// and the widget only ever reads it (see the ADR on that commit for the full comparison).
public struct HomeWidgetSnapshot: Sendable, Hashable, Codable {
    public let title: String
    public let gunName: String
    public let shotCount: Int
    /// Mean velocity (m/s). A 0-shot session isn't expected, but this is optional just
    /// in case.
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

    /// Mean speed with its unit symbol. `nil` for 0 shots.
    public var formattedMeanSpeed: String? {
        meanSpeedMetersPerSecond.map { speedUnit.formatted(metersPerSecond: $0) }
    }

    /// Mean joules formatted like `1.03 J`.
    public var formattedMeanJoules: String? {
        meanJoules.map { JouleFormat.labeled($0) }
    }
}

/// The gateway for reading and writing `HomeWidgetSnapshot` to an App Group-shared
/// `UserDefaults`.
///
/// Matches the key-value approach used by the rest of the app's settings (e.g.
/// `ChronoService.Keys`) rather than a JSON file — the already-used
/// `UserDefaults(suiteName:)` is easier to inject in tests than App Group container
/// file I/O, and avoids key collisions more easily.
public enum HomeWidgetSnapshotStore {
    /// The App Group registered in `project.yml`'s entitlements for both the app and the
    /// widget extension.
    public static let appGroupIdentifier = "group.com.yhakamay.muzzlemeter"

    private static let key = "muzzlemeter.homeWidgetSnapshot"

    /// Saves the snapshot. Overwrites any existing value (always holds just the "latest
    /// session").
    public static func save(_ snapshot: HomeWidgetSnapshot, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    /// Loads the snapshot. `nil` if no session has ended yet.
    public static func load(from defaults: UserDefaults) -> HomeWidgetSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HomeWidgetSnapshot.self, from: data)
    }
}
