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
    /// ユーザーが付けた名前。`nil`（または空）なら日時＋銃名の自動タイトルを使う。
    ///
    /// 自動タイトルを「保存された文字列」にしてしまうと、後から銃名を直したときに
    /// 過去のセッション名が食い違う。付けられた名前だけを持ち、無いときは都度組み立てる。
    var title: String?
    /// 計測時の銃プロファイル名（スナップショット）。
    var gunName: String
    /// 計測時の BB 重量（スナップショット、g）。
    var bbWeightGrams: Double

    // 銃の仕様も**値としてコピー**する（`GunProfile` を参照しない）。
    // 銃名・BB 重量と同じ理由で、後からプロファイルを直しても過去の計測の
    // 記録が書き換わってはいけない。既定値付きなのでライトウェイトマイグレーション。
    /// 計測時のパワーソース（`PowerSource.rawValue`）。空文字は「記録なし」。
    var gunPowerSourceRaw: String = ""
    var gunManufacturer: String = ""
    var gunModel: String = ""
    var gunInnerBarrelLengthMm: Int?

    @Relationship(deleteRule: .cascade, inverse: \ShotRecord.session)
    var shots: [ShotRecord] = []

    init(
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        title: String? = nil,
        gunName: String,
        bbWeightGrams: Double,
        gunPowerSource: PowerSource? = nil,
        gunManufacturer: String = "",
        gunModel: String = "",
        gunInnerBarrelLengthMm: Int? = nil
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.gunName = gunName
        self.bbWeightGrams = bbWeightGrams
        self.gunPowerSourceRaw = gunPowerSource?.rawValue ?? ""
        self.gunManufacturer = gunManufacturer
        self.gunModel = gunModel
        self.gunInnerBarrelLengthMm = gunInnerBarrelLengthMm
    }

    /// 記録されているパワーソース。古いセッション（列が無かった頃）は nil。
    var gunPowerSource: PowerSource? {
        PowerSource(rawValue: gunPowerSourceRaw)
    }

    /// 「メーカー モデル」を 1 行にしたもの。どちらも空なら nil。
    var gunMakeAndModel: String? {
        let parts = [gunManufacturer, gunModel]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: - 名前

    /// 名前が付いていないときに使う自動タイトル（日時 + 銃名）。
    var autoTitle: String {
        let date = startedAt.formatted(.dateTime.month().day().hour().minute())
        let gun = gunName.trimmingCharacters(in: .whitespacesAndNewlines)
        return gun.isEmpty ? date : "\(date)  \(gun)"
    }

    /// 画面にも CSV にも出す実効タイトル。名前があればそれ、無ければ自動タイトル。
    var displayTitle: String {
        customTitle ?? autoTitle
    }

    /// 空白だけの名前は「名前なし」として扱う（アラートで全消ししたら自動タイトルに戻る）。
    var customTitle: String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var hasCustomTitle: Bool { customTitle != nil }

    /// 名前を設定する。空文字なら自動タイトルへ戻す。
    func setTitle(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        title = trimmed.isEmpty ? nil : trimmed
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
