import Foundation

/// 1 発の計測結果。
///
/// 速度は常に **m/s** で保持し、表示単位（m/s / fps）への換算は `SpeedUnit` が行う。
/// 連射速度は **本体が送ってくる値**（`docs/PROTOCOL-apk-analysis.md` §8 の `rawRev`）を
/// そのまま保持する。本体が値を送らない場合は `nil` で、その場合は `RateOfFire` が
/// タイムスタンプ差からフォールバック推定する。
public struct Shot: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    /// 初速（m/s）。
    public let velocityMetersPerSecond: Double
    /// 本体が報告した連射速度（発/秒）。報告が無ければ `nil`。
    ///
    /// AC6000 の `FIRE_REPORT`（`0x52`）は `rawRev` を送ってくるが、**その単位が
    /// RPS なのか RPM なのか ×10 なのかは未検証**（`docs/PROTOCOL.md` §7.1 / §10-2）。
    /// そのため `AceChronoDecoder` はここを埋めず、生値を `rawRateOfFire` に入れる。
    /// 表示用の連射速度は `RateOfFire.estimateRPS` がタイムスタンプ差から推定する。
    public let rateOfFireRPS: Double?
    /// 本体が報告した連射速度の**生値**（`FIRE_REPORT` の `rawRev`）。
    /// 単発では 0 が来る。単位が確定するまでは換算せずそのまま持つ。
    public let rawRateOfFire: UInt16?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        velocityMetersPerSecond: Double,
        rateOfFireRPS: Double? = nil,
        rawRateOfFire: UInt16? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.velocityMetersPerSecond = velocityMetersPerSecond
        self.rateOfFireRPS = rateOfFireRPS
        self.rawRateOfFire = rawRateOfFire
    }

    /// BB 重量からこのショットの運動エネルギー（J）を求める。
    public func joules(massGrams: Double) -> Double {
        Energy.joules(massGrams: massGrams, velocityMetersPerSecond: velocityMetersPerSecond)
    }
}
