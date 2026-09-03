import Foundation
import Testing
@testable import MuzzlemeterKit

@Suite("WatchLiveState")
struct WatchLiveStateTests {
    @Test("待機状態")
    func idleState() {
        let state = WatchLiveState.idle()
        #expect(state.isSessionActive == false)
        #expect(state.shotCount == 0)
        #expect(state.recentShots.isEmpty)
        #expect(state.latestSpeedMetersPerSecond == nil)
    }

    @Test("最新のショットと平均が反映される")
    func derivesLatestShot() {
        let shots = [80.0, 85.0, 96.0].map { Shot(velocityMetersPerSecond: $0) }
        let state = WatchLiveState.derive(
            shots: shots,
            massGrams: 0.25,
            speedUnit: .metersPerSecond,
            energyLimitJoules: 0.98,
            target: nil,
            gunName: "次世代 M4",
            isSessionActive: true
        )
        #expect(state.shotCount == 3)
        #expect(state.latestSpeedMetersPerSecond == 96.0)
        #expect(state.margin == .over)
        #expect(state.recentShots.first?.velocityMetersPerSecond == 96.0)
    }

    @Test("最近のショットは新しい順、最大 10 件")
    func recentShotsCappedAndNewestFirst() {
        let velocities = (1...15).map { Double($0) + 80 }
        let shots = velocities.map { Shot(velocityMetersPerSecond: $0) }
        let state = WatchLiveState.derive(
            shots: shots,
            massGrams: 0.25,
            speedUnit: .metersPerSecond,
            energyLimitJoules: 0.98,
            target: nil,
            gunName: "銃",
            isSessionActive: true
        )
        #expect(state.recentShots.count == 10)
        // 最後に撃った（15 発目、95 m/s）が先頭。
        #expect(state.recentShots.first?.velocityMetersPerSecond == 95.0)
        // 最初の 5 発ぶんは切り捨てられている。
        #expect(state.recentShots.last?.velocityMetersPerSecond == 86.0)
    }

    @Test("目標発数はそのまま渡る")
    func targetPassesThrough() {
        let state = WatchLiveState.derive(
            shots: [Shot(velocityMetersPerSecond: 80)],
            massGrams: 0.20,
            speedUnit: .metersPerSecond,
            energyLimitJoules: 0.98,
            target: ShotTarget(10),
            gunName: "銃",
            isSessionActive: true
        )
        #expect(state.targetCount == 10)
    }
}

@Suite("WatchShotMessage")
struct WatchShotMessageTests {
    @Test("ショットが無ければ作れない")
    func nilWhenNoShots() {
        #expect(WatchShotMessage(state: .idle()) == nil)
    }

    @Test("最新のショットから作られる")
    func buildsFromLatestShot() {
        let shots = [80.0, 92.0].map { Shot(velocityMetersPerSecond: $0) }
        let state = WatchLiveState.derive(
            shots: shots,
            massGrams: 0.25,
            speedUnit: .metersPerSecond,
            energyLimitJoules: 0.98,
            target: ShotTarget(5),
            gunName: "次世代 M4",
            isSessionActive: true
        )
        let message = try! #require(WatchShotMessage(state: state))
        #expect(message.shot.velocityMetersPerSecond == 92.0)
        #expect(message.shotCount == 2)
        #expect(message.targetCount == 5)
        #expect(message.gunName == "次世代 M4")
    }
}

@Suite("WatchPayloadCoding")
struct WatchPayloadCodingTests {
    @Test("辞書へ詰めてそのまま復元できる")
    func roundTripsThroughDictionary() {
        let state = WatchLiveState.derive(
            shots: [Shot(velocityMetersPerSecond: 88.5)],
            massGrams: 0.25,
            speedUnit: .metersPerSecond,
            energyLimitJoules: 0.98,
            target: nil,
            gunName: "銃",
            isSessionActive: true
        )
        let dictionary = try! #require(WatchPayloadCoding.encode(state))
        let decoded = WatchPayloadCoding.decode(WatchLiveState.self, from: dictionary)
        #expect(decoded == state)
    }

    @Test("鍵が無い辞書からは復元できない")
    func decodeFailsWithoutPayload() {
        #expect(WatchPayloadCoding.decode(WatchLiveState.self, from: [:]) == nil)
    }
}
