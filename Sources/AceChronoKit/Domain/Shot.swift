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
    public let rateOfFireRPS: Double?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        velocityMetersPerSecond: Double,
        rateOfFireRPS: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.velocityMetersPerSecond = velocityMetersPerSecond
        self.rateOfFireRPS = rateOfFireRPS
    }

    /// BB 重量からこのショットの運動エネルギー（J）を求める。
    public func joules(massGrams: Double) -> Double {
        Energy.joules(massGrams: massGrams, velocityMetersPerSecond: velocityMetersPerSecond)
    }
}
