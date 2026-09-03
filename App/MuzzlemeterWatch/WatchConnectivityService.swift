import Foundation
import MuzzlemeterKit
import Observation
import WatchConnectivity

/// Watch 側の `WatchConnectivity`。iPhone から届く計測状態を受け取って表示するだけで、
/// **BLE には一切触れない**（`docs/UX-ROADMAP.md` Round E の方針。中心は iPhone のまま）。
///
/// 2 つの経路を受ける（iPhone 側 `WatchConnectivityService` の ADR も参照）:
/// - `didReceiveMessage`: 1 発ごとの即時通知（`WatchShotMessage`）。iPhone アプリが
///   前面にあるときだけ届く。既存の `state` へ**継ぎ足す**。
/// - `didReceiveApplicationContext`: セッションの節目（開始・終了・破棄）。
///   `WatchLiveState` 全体が届き、そのまま置き換える。**Watch アプリが閉じられていても、
///   次に開いたときにこの経路で最新状態が届く**ので、閉じていても壊れない。
@MainActor
@Observable
final class WatchConnectivityService: NSObject {
    private(set) var state: WatchLiveState = .idle()
    /// iPhone アプリが前面にあり、`sendMessage` が届く状態か。
    private(set) var isReachable = false
    /// ペアリングした iPhone に Muzzlemeter 本体がインストールされているか。
    private(set) var isCompanionInstalled = false

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    override init() {
        super.init()
        guard let session else { return }
        session.delegate = self
        session.activate()
    }
}

extension WatchConnectivityService: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        // `WCSession` は `Sendable` ではないので、`Task { @MainActor in ... }` へ
        // そのまま渡さず、ここ（デリゲートの呼び出しスレッド）で値だけ取り出しておく。
        let reachable = session.isReachable
        let companionInstalled = session.isCompanionAppInstalled
        // 起動直後は直前の applicationContext をまだ読んでいないことがあるので、
        // 明示的に読み直す（届いたはずの状態を取りこぼさないため）。
        let cached = WatchPayloadCoding.decode(WatchLiveState.self, from: session.receivedApplicationContext)
        Task { @MainActor in
            self.isReachable = reachable
            self.isCompanionInstalled = companionInstalled
            if let cached {
                self.state = cached
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let payload = WatchPayloadCoding.decode(WatchShotMessage.self, from: message) else { return }
        Task { @MainActor in self.apply(message: payload) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let newState = WatchPayloadCoding.decode(WatchLiveState.self, from: applicationContext) else { return }
        Task { @MainActor in self.state = newState }
    }

    /// `WatchShotMessage`（直近 1 発だけ）を、いま持っている `state` へ継ぎ足す。
    /// セッションの開始・終了は `didReceiveApplicationContext` の役目なので、
    /// ここでは `isSessionActive` を常に true にするだけ（受け取れているのは
    /// 進行中のセッションのショットに限られるため）。
    @MainActor
    private func apply(message: WatchShotMessage) {
        var recent = state.recentShots
        recent.insert(message.shot, at: 0)
        if recent.count > 10 { recent.removeLast(recent.count - 10) }
        state = WatchLiveState(
            gunName: message.gunName,
            isSessionActive: true,
            shotCount: message.shotCount,
            targetCount: message.targetCount,
            latestSpeedMetersPerSecond: message.shot.velocityMetersPerSecond,
            latestJoules: message.shot.joules,
            margin: message.margin,
            speedUnit: message.speedUnit,
            recentShots: recent,
            updatedAt: Date()
        )
    }
}
