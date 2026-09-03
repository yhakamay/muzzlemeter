import Foundation
import SwiftData

/// 起動時に一度だけ走る、**保存済みデータの作り直し**。
///
/// スキーマそのものは変えていない（列の追加だけ＝軽量マイグレーション）。変わったのは
/// **値の意味**で、旧「パワーソース」1 列に押し込んであった区分とガス種別を、
/// 新しい 2 列へ振り分ける。列の追加と値の派生だけで済むので、`VersionedSchema` と
/// `SchemaMigrationPlan` は要らない（`docs/UX-ROADMAP.md` Round A）。
///
/// 冪等。移行済み（区分が入っている）レコードは触らない。
@MainActor
enum StoreMigration {
    static func run(in context: ModelContext) {
        var changed = false
        changed = migrateProfiles(in: context) || changed
        changed = migrateSessions(in: context) || changed
        if changed { try? context.save() }
    }

    private static func migrateProfiles(in context: ModelContext) -> Bool {
        guard let profiles = try? context.fetch(FetchDescriptor<GunProfile>()) else { return false }
        var changed = false
        for profile in profiles where profile.powerCategoryRaw.isEmpty {
            let split = split(legacy: profile.powerSourceRaw)
            profile.powerCategoryRaw = split.category.rawValue
            // ガス種別はプロファイル側では「既定値」になる。旧値がガスでなければ
            // 既定の HFC134a のまま（区分がガスでない間は表示もされない）。
            if let gas = split.gasType { profile.defaultGasTypeRaw = gas.rawValue }
            changed = true
        }
        return changed
    }

    private static func migrateSessions(in context: ModelContext) -> Bool {
        guard let sessions = try? context.fetch(FetchDescriptor<Session>()) else { return false }
        var changed = false
        for session in sessions
        where session.gunPowerCategoryRaw.isEmpty && !session.gunPowerSourceRaw.isEmpty {
            let split = split(legacy: session.gunPowerSourceRaw)
            session.gunPowerCategoryRaw = split.category.rawValue
            if let gas = split.gasType { session.gasTypeRaw = gas.rawValue }
            changed = true
        }
        return changed
    }

    /// 旧 `PowerSource.rawValue` を「区分 + ガス種別」に割る。
    ///
    /// 表記ゆれ（`gasHFC134a` / `gas_hfc134a`）を吸収するため、英小文字化して
    /// 区切り文字を落としてから比べる。読めない値は電動として扱う（落とさない）。
    static func split(legacy raw: String) -> (category: PowerCategory, gasType: GasType?) {
        let key = raw.lowercased().replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch key {
        case "gashfc134a": return (.gas, .hfc134a)
        case "gashfc152a": return (.gas, .hfc152a)
        case "gasco2": return (.gas, .co2)
        case "gasgreengas": return (.gas, .greenGas)
        case "gas": return (.gas, nil)
        case "springair": return (.springAir, nil)
        case "hpa": return (.hpa, nil)
        default: return (.electric, nil)
        }
    }
}
