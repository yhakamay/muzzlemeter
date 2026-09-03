import Foundation

/// Apple Watch アプリの「最近 10 発」に出す 1 行。
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

/// Apple Watch アプリが表示する、進行中セッションの状態。
///
/// **BLE の中心（central）は iPhone のまま**（`docs/UX-ROADMAP.md` Round E の方針）。
/// Watch は本体に直接繋がず、iPhone アプリが `WatchConnectivity` 経由でこの値を渡すだけ。
/// そのため、ここに置くのは「渡す値そのもの」と「渡す値をショット列から作る計算」で、
/// `WCSession` のような通信の詳細はアプリ側（`WatchConnectivityService`）に置く
/// （キットを watchOS だけでなく macOS の CLI もビルド対象にしているため、
/// `WatchConnectivity` に依存するコードをここへ持ち込めない）。
public struct WatchLiveState: Sendable, Hashable, Codable {
    public let gunName: String
    public let isSessionActive: Bool
    public let shotCount: Int
    /// N 発モードの目標。`nil` なら手動で締めるセッション。
    public let targetCount: Int?
    public let latestSpeedMetersPerSecond: Double?
    public let latestJoules: Double?
    /// 直近 1 発の規制上限に対する段階。まだ 1 発も無ければ `.safe`。
    public let margin: EnergyMargin
    public let speedUnit: SpeedUnit
    /// 新しい順、最大 10 件。
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

    /// 接続前 / セッション未開始の既定状態。
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

    /// ショット列から Watch へ渡す状態を作る。iPhone 側（`ChronoService`）の
    /// `currentShots` / `massGrams` / `variables.target` をそのまま渡せばよい。
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

/// 1 発ごとに `WCSession.sendMessage` で送る、軽量な通知。
///
/// `WatchLiveState` 全体（最大 10 発ぶん）を毎発送るとフルオートで通信量が無駄に増える。
/// 発射のたびに送るのはこの小さい方だけにし、`updateApplicationContext` による
/// `WatchLiveState` 全体の同期は「セッションの区切り（開始・終了）」でだけ行う
/// （詳細は該当コミットの ADR）。
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

    /// 直近のショットが無い状態（＝まだ何も送るものが無い）からは作れない。
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

/// `WCSession` の `[String: Any]` ペイロードと `Codable` 型の間を仲立ちする。
///
/// `WatchConnectivity` そのものへは依存しない（macOS でもビルドされるキットに
/// `import WatchConnectivity` を持ち込めない）ので、辞書 1 個に JSON を 1 個詰める、
/// という**辞書の形だけ**をここで決める。実際に `sendMessage` / `updateApplicationContext`
/// を呼ぶのはアプリ側・Watch 側それぞれの `WatchConnectivityService`。
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
