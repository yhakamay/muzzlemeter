import Foundation
import MuzzlemeterKit
import WidgetKit

/// セッションを終えるたびに、ホーム画面ウィジェット用のまとめを App Group 共有の
/// `UserDefaults` へ書く。
///
/// **なぜ SwiftData のストアを直接共有しないか**（ADR は該当コミット参照、要点だけ）:
/// ウィジェット拡張は別プロセスなので、App Group 越しに同じ SwiftData コンテナを
/// 開けなくはない。だが `Session` のスキーマが変わるたびに拡張側も
/// 追随させないと壊れ、拡張はただ「最新セッションの数値をいくつか出す」だけなので
/// 見合わない。**書き出す値だけを固定した小さな snapshot**（`HomeWidgetSnapshot`）に
/// 絞り、アプリのスキーマがどう変わっても拡張は影響を受けない形にした。
struct HomeWidgetSnapshotWriter {
    private let defaults: UserDefaults?

    init(appGroupIdentifier: String = HomeWidgetSnapshotStore.appGroupIdentifier) {
        self.defaults = UserDefaults(suiteName: appGroupIdentifier)
    }

    /// セッション終了時に呼ぶ。**破棄されたセッションでは呼ばない**
    /// （誤射をまとめて捨てたものがホーム画面に出てしまうため）。
    ///
    /// `speedUnit` はアプリ全体の設定（`ChronoService.speedUnit`）。それは
    /// `UserDefaults.standard` にあり、別プロセスのウィジェット拡張からは見えないので、
    /// この snapshot に焼き込んで渡す（呼び出し元が現在の設定を渡す）。
    func write(session: Session, speedUnit: SpeedUnit) {
        guard let defaults else { return }
        let stats = session.stats
        let snapshot = HomeWidgetSnapshot(
            title: session.displayTitle,
            gunName: session.gunName,
            shotCount: stats.count,
            meanSpeedMetersPerSecond: stats.meanMetersPerSecond,
            meanJoules: stats.meanJoules,
            overLimitCount: EnergyLimit.overLimitCount(
                shots: session.domainShots,
                massGrams: session.bbWeightGrams,
                limitJoules: session.energyLimitJoules
            ),
            endedAt: session.endedAt ?? Date(),
            speedUnit: speedUnit
        )
        HomeWidgetSnapshotStore.save(snapshot, to: defaults)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.sessionSummary)
    }
}
