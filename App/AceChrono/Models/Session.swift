import AceChronoKit
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
    /// 計測時の銃プロファイル名（スナップショット）。
    var gunName: String
    /// 計測時の BB 重量（スナップショット、g）。
    var bbWeightGrams: Double

    @Relationship(deleteRule: .cascade, inverse: \ShotRecord.session)
    var shots: [ShotRecord] = []

    init(
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        gunName: String,
        bbWeightGrams: Double
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.gunName = gunName
        self.bbWeightGrams = bbWeightGrams
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
