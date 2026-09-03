// ActivityKit はまだ Swift 6 の厳格な並行性チェックに向けて Sendable 対応されていない
// （`Activity<Attributes>` を nonisolated な async メソッドへ渡すと「送れない」と怒られる）。
// `Sources/MuzzlemeterKit/Transport/CoreBluetoothTransport.swift` が CoreBluetooth に対して
// 同じ理由で `@preconcurrency` を付けているのと同じ対応。
@preconcurrency import ActivityKit
import Foundation
import MuzzlemeterKit
import os

/// ライブアクティビティ（ロック画面 / Dynamic Island）の開始・更新・終了。
///
/// `ChronoService` から呼ばれる。表示する値そのものは
/// `MuzzlemeterKit.LiveActivityContent.derive` が決め、ここは ActivityKit の
/// 手続き（`Activity.request` / `update` / `end`）と**更新頻度の間引き**だけを持つ。
///
/// フルオートでは 1 秒間に何十発も `report(shots:...)` が呼ばれうる。毎回
/// `Activity.update` を呼ぶと ActivityKit 側のレート制限に引っかかって更新が
/// 捨てられたり、ロック画面がちらつく。`LiveActivityUpdateThrottle`
/// （キット・純粋ロジック・テスト済み）で「直近の更新から 1 秒経っているか」だけ判定し、
/// 経っていなければ**その発だけ更新をスキップ**する（次の発でまた判定するので、
/// 最終的な表示が古いまま固まることはない。セッション終了時は必ず最終状態で更新する）。
@MainActor
final class LiveActivityService {
    private let throttle: LiveActivityUpdateThrottle
    private let logger = Logger(subsystem: "com.yhakamay.muzzlemeter", category: "LiveActivity")

    private var activity: Activity<MuzzlemeterLiveActivityAttributes>?
    private var lastUpdateAt: Date?

    init(throttle: LiveActivityUpdateThrottle = LiveActivityUpdateThrottle()) {
        self.throttle = throttle
    }

    /// 実機・シミュレータの両方で、ユーザーがライブアクティビティを許可しているか。
    private var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// セッション開始（1 発目）で呼ぶ。既に走っていれば何もしない
    /// （前のセッションを終えずに次が始まることは無い設計だが、二重起動を防ぐ）。
    func start(content: LiveActivityContent, startedAt: Date) {
        guard activity == nil, areActivitiesEnabled else { return }
        let attributes = MuzzlemeterLiveActivityAttributes(startedAt: startedAt)
        let state = ActivityContent(state: content, staleDate: nil)
        do {
            activity = try Activity.request(attributes: attributes, content: state)
            lastUpdateAt = Date()
        } catch {
            // ライブアクティビティは「あれば嬉しい」機能で、計測そのものには関わらない。
            // 失敗しても計測を止めない（ログだけ残す)。
            logger.error("ライブアクティビティの開始に失敗: \(error.localizedDescription)")
        }
    }

    /// 1 発ごとに呼ぶ。**間引き判定はここで行う**（呼ぶ側は毎発呼んでよい）。
    func report(content: LiveActivityContent) {
        guard let activity else { return }
        let now = Date()
        guard throttle.shouldUpdate(now: now, lastUpdate: lastUpdateAt) else { return }
        lastUpdateAt = now
        Task {
            await activity.update(ActivityContent(state: content, staleDate: nil))
        }
    }

    /// セッション終了・破棄で呼ぶ。**間引きせず必ず最終状態を反映する。**
    func end(content: LiveActivityContent) {
        guard let activity else { return }
        self.activity = nil
        lastUpdateAt = nil
        Task {
            await activity.end(
                ActivityContent(state: content, staleDate: nil),
                dismissalPolicy: .after(.now.addingTimeInterval(30))
            )
        }
    }
}
