import Foundation

/// One row shown in the Apple Watch app's "last 10 shots" list.
public struct WatchShotEntry: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let velocityMetersPerSecond: Double
    public let joules: Double

    public init(id: UUID, timestamp: Date, velocityMetersPerSecond: Double, joules: Double) {
        self.id = id
        self.timestamp = timestamp
        self.velocityMetersPerSecond = velocityMetersPerSecond
        self.joules = joules
    }

    public init(shot: Shot, massGrams: Double) {
        self.init(
            id: shot.id,
            timestamp: shot.timestamp,
            velocityMetersPerSecond: shot.velocityMetersPerSecond,
            joules: shot.joules(massGrams: massGrams)
        )
    }
}

/// The state of an in-progress session as shown by the Apple Watch app.
///
/// **The BLE central stays the iPhone** (per the `docs/UX-ROADMAP.md` Round E policy).
/// The watch never connects to the device directly; the iPhone app just hands it this
/// value over `WatchConnectivity`. Because of that, what lives here is only "the value
/// being passed" and "the calculation that builds that value from the shot list" —
/// communication details like `WCSession` live on the app side
/// (`WatchConnectivityService`) instead (the kit also targets the macOS CLI, not just
/// watchOS, so code depending on `WatchConnectivity` can't live here).
public struct WatchLiveState: Sendable, Hashable, Codable {
    public let gunName: String
    public let isSessionActive: Bool
    public let shotCount: Int
    /// The N-shot mode target. `nil` means the session is stopped manually.
    public let targetCount: Int?
    public let latestSpeedMetersPerSecond: Double?
    public let latestJoules: Double?
    /// The most recent shot's stage relative to the regulation limit. `.safe` if there's
    /// no shot yet.
    public let margin: EnergyMargin
    public let speedUnit: SpeedUnit
    /// Newest first, at most 10 entries.
    public let recentShots: [WatchShotEntry]
    public let updatedAt: Date

    public init(
        gunName: String,
        isSessionActive: Bool,
        shotCount: Int,
        targetCount: Int?,
        latestSpeedMetersPerSecond: Double?,
        latestJoules: Double?,
        margin: EnergyMargin,
        speedUnit: SpeedUnit,
        recentShots: [WatchShotEntry],
        updatedAt: Date
    ) {
        self.gunName = gunName
        self.isSessionActive = isSessionActive
        self.shotCount = shotCount
        self.targetCount = targetCount
        self.latestSpeedMetersPerSecond = latestSpeedMetersPerSecond
        self.latestJoules = latestJoules
        self.margin = margin
        self.speedUnit = speedUnit
        self.recentShots = recentShots
        self.updatedAt = updatedAt
    }

    /// The default state before connecting / before a session has started.
    public static func idle(speedUnit: SpeedUnit = .metersPerSecond) -> WatchLiveState {
        WatchLiveState(
            gunName: "",
            isSessionActive: false,
            shotCount: 0,
            targetCount: nil,
            latestSpeedMetersPerSecond: nil,
            latestJoules: nil,
            margin: .safe,
            speedUnit: speedUnit,
            recentShots: [],
            updatedAt: .distantPast
        )
    }

    /// Builds the state handed to the watch from a shot list. The iPhone side
    /// (`ChronoService`) can pass its `currentShots` / `massGrams` /
    /// `variables.target` straight through.
    public static func derive(
        shots: [Shot],
        massGrams: Double,
        speedUnit: SpeedUnit,
        energyLimitJoules: Double,
        target: ShotTarget?,
        gunName: String,
        isSessionActive: Bool,
        now: Date = Date()
    ) -> WatchLiveState {
        let last = shots.last
        let margin = last.map {
            EnergyLimit.margin(
                massGrams: massGrams,
                velocityMetersPerSecond: $0.velocityMetersPerSecond,
                limitJoules: energyLimitJoules
            )
        } ?? .safe
        let recent = shots.suffix(10).reversed().map {
            WatchShotEntry(shot: $0, massGrams: massGrams)
        }
        return WatchLiveState(
            gunName: gunName,
            isSessionActive: isSessionActive,
            shotCount: shots.count,
            targetCount: target?.count,
            latestSpeedMetersPerSecond: last?.velocityMetersPerSecond,
            latestJoules: last.map { $0.joules(massGrams: massGrams) },
            margin: margin,
            speedUnit: speedUnit,
            recentShots: Array(recent),
            updatedAt: now
        )
    }
}

/// A lightweight notification sent via `WCSession.sendMessage` for each individual shot.
///
/// Sending the full `WatchLiveState` (holding up to 10 shots) on every single shot would
/// waste bandwidth needlessly during full-auto. Only this small message is sent on every
/// shot; syncing the full `WatchLiveState` via `updateApplicationContext` happens only at
/// "session boundaries" (start/end) (see the ADR on that commit for details).
public struct WatchShotMessage: Sendable, Hashable, Codable {
    public let shot: WatchShotEntry
    public let shotCount: Int
    public let targetCount: Int?
    public let margin: EnergyMargin
    public let speedUnit: SpeedUnit
    public let gunName: String

    public init(
        shot: WatchShotEntry,
        shotCount: Int,
        targetCount: Int?,
        margin: EnergyMargin,
        speedUnit: SpeedUnit,
        gunName: String
    ) {
        self.shot = shot
        self.shotCount = shotCount
        self.targetCount = targetCount
        self.margin = margin
        self.speedUnit = speedUnit
        self.gunName = gunName
    }

    /// Can't be built when there's no recent shot (i.e. nothing to send yet).
    public init?(state: WatchLiveState) {
        guard let latest = state.recentShots.first else { return nil }
        self.init(
            shot: latest,
            shotCount: state.shotCount,
            targetCount: state.targetCount,
            margin: state.margin,
            speedUnit: state.speedUnit,
            gunName: state.gunName
        )
    }
}

/// Bridges between `WCSession`'s `[String: Any]` payload and `Codable` types.
///
/// Doesn't depend on `WatchConnectivity` itself (the kit also builds for macOS, so
/// `import WatchConnectivity` can't be brought in here) — this only decides **the shape
/// of the dictionary**: one JSON blob packed into one dictionary entry. Actually calling
/// `sendMessage` / `updateApplicationContext` is done by each side's own
/// `WatchConnectivityService` (app side and watch side).
public enum WatchPayloadCoding {
    private static let payloadKey = "muzzlemeter.json"

    public static func encode(_ value: some Encodable) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return [payloadKey: data]
    }

    public static func decode<T: Decodable>(_ type: T.Type, from dictionary: [String: Any]) -> T? {
        guard let data = dictionary[payloadKey] as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
