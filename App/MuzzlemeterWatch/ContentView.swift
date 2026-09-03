import MuzzlemeterKit
import SwiftUI

/// Apple Watch アプリの本体画面（`docs/UX-ROADMAP.md` Round E の 12）。
///
/// **本体には直接繋がず、iPhone から `WatchConnectivity` で渡された値をそのまま出す**
/// だけの画面。ここで統計やジュールを計算し直したりしない
/// （`WatchLiveState` は既に計算済みの値として届く）。
struct ContentView: View {
    @Environment(WatchConnectivityService.self) private var connectivity

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ConnectionBadge(connectivity: connectivity)
                SpeedDisplay(state: connectivity.state)
                JoulesAndCountRow(state: connectivity.state)
                if !connectivity.state.recentShots.isEmpty {
                    RecentShotsList(state: connectivity.state)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .navigationTitle(Text(verbatim: "Muzzlemeter"))
    }
}

/// 接続状態。iPhone のアプリが前面に無くても、直前に届いた `applicationContext` の値は
/// 出し続ける（「閉じていても壊れない」の見た目上の裏付け）。
private struct ConnectionBadge: View {
    let connectivity: WatchConnectivityService

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: connectivity.isReachable ? "iphone.gen3.radiowaves.left.and.right" : "iphone.slash")
                .foregroundStyle(connectivity.isReachable ? .green : .secondary)
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        if !connectivity.isCompanionInstalled {
            String(localized: "iPhone 側アプリ未検出")
        } else if connectivity.isReachable {
            String(localized: "接続中")
        } else if connectivity.state.isSessionActive {
            String(localized: "iPhone がそばにありません")
        } else {
            String(localized: "待機中")
        }
    }
}

/// 直近 1 発の速度。**巨大な数字**で出す（腕を上げてすぐ読めるように）。
private struct SpeedDisplay: View {
    let state: WatchLiveState

    var body: some View {
        VStack(spacing: 0) {
            if let speed = state.latestSpeedMetersPerSecond {
                Text(state.speedUnit.format(metersPerSecond: speed))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(state.margin.tint ?? .primary)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(state.speedUnit.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: "—")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text("まだ計測なし")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !state.gunName.isEmpty {
                Text(state.gunName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

/// ジュールと発数（N 発モードなら「7 / 10」）。
private struct JoulesAndCountRow: View {
    let state: WatchLiveState

    var body: some View {
        HStack {
            Label(joulesText, systemImage: "bolt.fill")
            Spacer()
            Label(shotCountText, systemImage: "number")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var joulesText: String {
        guard let joules = state.latestJoules else { return "—" }
        return String(localized: "\(JouleFormat.value(joules)) J")
    }

    private var shotCountText: String {
        if let target = state.targetCount {
            "\(state.shotCount) / \(target)"
        } else {
            "\(state.shotCount)"
        }
    }
}

/// 直近 10 発。新しい順。
private struct RecentShotsList: View {
    let state: WatchLiveState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("直近\(state.recentShots.count)発")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(state.recentShots) { shot in
                HStack {
                    Text(state.speedUnit.formatted(metersPerSecond: shot.velocityMetersPerSecond))
                        .font(.caption.monospacedDigit())
                    Spacer()
                    Text(String(localized: "\(JouleFormat.value(shot.joules)) J"))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }
}

#Preview {
    NavigationStack {
        ContentView()
    }
    .environment(WatchConnectivityService())
}
