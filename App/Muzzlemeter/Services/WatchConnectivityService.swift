import Foundation
import MuzzlemeterKit
import WatchConnectivity
import os

/// iPhone 側の `WatchConnectivity`。Apple Watch アプリへ計測状態を渡す。
///
/// **BLE の中心は iPhone のまま**（`docs/UX-ROADMAP.md` Round E の方針。Watch 側では
/// BLE を実装しない）。Watch は本体に直接繋がず、`ChronoService` がここを呼んで
/// Watch アプリへ転送するだけ。
///
/// 2 つの経路を使い分ける（詳細は該当コミットの ADR）:
/// - `sendMessage`: 1 発ごとの即時通知。Watch アプリが前面にあるときだけ届く
///   （`isReachable`）。フルオートでの連投は `LiveActivityUpdateThrottle` と同じ
///   間引きを掛ける（同じ「1 秒に 1 回」で十分読める）。
/// - `updateApplicationContext`: セッションの節目（開始・終了・破棄）で送る、
///   状態全体のスナップショット。**Watch アプリが閉じていても、システムが保持していて
///   次に開いたときに最新値が届く**。「Watch アプリを閉じていても壊れない」という
///   要求はこちらで満たす（`sendMessage` だけでは前面にいない Watch には何も届かない）。
@MainActor
final class WatchConnectivityService: NSObject {
    private let throttle: LiveActivityUpdateThrottle
    private var lastMessageAt: Date?
    private let logger = Logger(subsystem: "com.yhakamay.muzzlemeter", category: "WatchConnectivity")

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    init(throttle: LiveActivityUpdateThrottle = LiveActivityUpdateThrottle()) {
        self.throttle = throttle
        super.init()
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// 1 発ごとに呼ぶ。前面の Watch アプリへ即時通知する（間引きあり、未起動なら何もしない）。
    func reportShot(state: WatchLiveState) {
        guard let session, session.isReachable, let message = WatchShotMessage(state: state) else { return }
        let now = Date()
        guard throttle.shouldUpdate(now: now, lastUpdate: lastMessageAt) else { return }
        guard let payload = WatchPayloadCoding.encode(message) else { return }
        lastMessageAt = now
        session.sendMessage(payload, replyHandler: nil) { [logger] error in
            // Watch アプリが前面に無い・接続が切れているなど、日常的に起きる失敗。
            // 計測は止めない（ログだけ残す）。
            logger.debug("sendMessage は失敗（Watch 未起動などで正常）: \(error.localizedDescription)")
        }
    }

    /// セッションの節目（開始・終了・破棄）で呼ぶ。Watch アプリが閉じていても届く。
    func syncState(_ state: WatchLiveState) {
        guard let session, let payload = WatchPayloadCoding.encode(state) else { return }
        do {
            try session.updateApplicationContext(payload)
        } catch {
            logger.error("updateApplicationContext に失敗: \(error.localizedDescription)")
        }
    }
}

extension WatchConnectivityService: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    // iPhone を 2 台使う設定（乗り換え）で古いセッションが非アクティブになったとき。
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    // 乗り換え完了後、新しい iPhone 側で使えるように再アクティブ化する。
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
