import MuzzlemeterKit
import Foundation
import SwiftData

/// 保存された 1 発。`MuzzlemeterKit.Shot` の永続化表現。
///
/// ドメイン型 (`Shot`) と分けているのは、SwiftData の `@Model` がクラス・可変・
/// `Sendable` でないため、統計計算やテストで扱う純粋な値と混ぜたくないから。
@Model
final class ShotRecord {
    var timestamp: Date
    /// 初速（m/s）。表示単位への換算は `SpeedUnit` が行う。
    var velocityMetersPerSecond: Double
    /// 本体が報告した連射速度（発/秒）。報告が無ければ nil。
    var rateOfFireRPS: Double?

    var session: Session?

    init(
        timestamp: Date = Date(),
        velocityMetersPerSecond: Double,
        rateOfFireRPS: Double? = nil,
        session: Session? = nil
    ) {
        self.timestamp = timestamp
        self.velocityMetersPerSecond = velocityMetersPerSecond
        self.rateOfFireRPS = rateOfFireRPS
        self.session = session
    }

    convenience init(shot: Shot, session: Session? = nil) {
        self.init(
            timestamp: shot.timestamp,
            velocityMetersPerSecond: shot.velocityMetersPerSecond,
            rateOfFireRPS: shot.rateOfFireRPS,
            session: session
        )
    }

    var asShot: Shot {
        Shot(
            timestamp: timestamp,
            velocityMetersPerSecond: velocityMetersPerSecond,
            rateOfFireRPS: rateOfFireRPS
        )
    }

    func joules(massGrams: Double) -> Double {
        Energy.joules(massGrams: massGrams, velocityMetersPerSecond: velocityMetersPerSecond)
    }
}
