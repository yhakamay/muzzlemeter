import Foundation
import SwiftData
import Testing
@testable import MuzzlemeterAppModels
@testable import MuzzlemeterKit

/// デモモードで作った記録の扱い。
///
/// 実測とデモが混ざるのは、このアプリでは単なる紛らわしさではなく**危険**なので、
/// 印の付き方・消し方・締め方は保存層のレベルで固定しておく。
@Suite("デモセッション")
@MainActor
struct DemoSessionTests {
    /// インメモリのストア。ディスクにも `UserDefaults` にも触らない。
    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, ShotRecord.self, GunProfile.self])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @discardableResult
    private func insertSession(
        into context: ModelContext,
        isDemo: Bool,
        endedAt: Date? = Date(timeIntervalSince1970: 2_000),
        velocities: [Double] = [90.0, 91.0],
        startedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> Session {
        let session = Session(
            startedAt: startedAt,
            endedAt: endedAt,
            gunName: isDemo ? "デモの銃" : "実測の銃",
            isDemo: isDemo
        )
        context.insert(session)
        for (index, velocity) in velocities.enumerated() {
            let record = ShotRecord(
                timestamp: startedAt.addingTimeInterval(Double(index) * 2),
                velocityMetersPerSecond: velocity,
                session: session
            )
            context.insert(record)
            session.shots.append(record)
        }
        try? context.save()
        return session
    }

    // MARK: - 印

    @Test("既定では実測（印が付かない）")
    func realSessionIsNotFlagged() throws {
        let context = try makeContext()
        let session = Session(gunName: "実測の銃")
        context.insert(session)
        #expect(session.isDemo == false)
    }

    @Test("デモで作ったセッションには印が残る")
    func demoSessionKeepsItsFlag() throws {
        let context = try makeContext()
        let demo = insertSession(into: context, isDemo: true)
        let real = insertSession(into: context, isDemo: false)

        // 保存して読み直しても印が残る（表示のときの判定ではなく列として持っている）。
        let all = try context.fetch(FetchDescriptor<Session>())
        #expect(all.count == 2)
        #expect(demo.isDemo)
        #expect(!real.isDemo)
        #expect(DemoSessionStore.demoSessionCount(in: context) == 1)
        #expect(DemoSessionStore.demoSessions(in: context).first?.gunName == "デモの銃")
    }

    // MARK: - デモデータの削除

    @Test("デモデータの削除はデモのセッションだけを消す")
    func deletingDemoDataKeepsRealSessions() throws {
        let context = try makeContext()
        insertSession(into: context, isDemo: true)
        insertSession(into: context, isDemo: true)
        insertSession(into: context, isDemo: false)

        let deleted = DemoSessionStore.deleteDemoSessions(in: context)
        #expect(deleted == 2)

        let remaining = try context.fetch(FetchDescriptor<Session>())
        #expect(remaining.count == 1)
        #expect(remaining.allSatisfy { !$0.isDemo })
        #expect(remaining.first?.gunName == "実測の銃")
    }

    @Test("デモのショットも一緒に消える")
    func deletingDemoDataRemovesItsShots() throws {
        let context = try makeContext()
        insertSession(into: context, isDemo: true, velocities: [90, 91, 92])
        insertSession(into: context, isDemo: false, velocities: [88, 89])

        DemoSessionStore.deleteDemoSessions(in: context)

        let shots = try context.fetch(FetchDescriptor<ShotRecord>())
        #expect(shots.count == 2)
    }

    @Test("デモのセッションが無ければ何も消さない")
    func deletingWithNoDemoSessionsIsANoOp() throws {
        let context = try makeContext()
        insertSession(into: context, isDemo: false)

        #expect(DemoSessionStore.deleteDemoSessions(in: context) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Session>()) == 1)
    }

    // MARK: - デモを切ったとき

    @Test("デモモードを切ると、開いているデモセッションが締まる")
    func turningDemoOffClosesOpenDemoSessions() throws {
        let context = try makeContext()
        let start = Date(timeIntervalSince1970: 5_000)
        let open = insertSession(
            into: context,
            isDemo: true,
            endedAt: nil,
            velocities: [90, 91, 92],
            startedAt: start
        )
        #expect(open.isActive)

        let closed = DemoSessionStore.closeOpenDemoSessions(in: context)

        #expect(closed == 1)
        #expect(!open.isActive)
        // 最後のショットの時刻で締める（起動時の後始末と同じ規則）。
        #expect(open.endedAt == start.addingTimeInterval(4))
    }

    @Test("デモを切っても、開いている実測のセッションには触らない")
    func turningDemoOffLeavesRealSessionsRunning() throws {
        let context = try makeContext()
        let realOpen = insertSession(into: context, isDemo: false, endedAt: nil)

        #expect(DemoSessionStore.closeOpenDemoSessions(in: context) == 0)
        #expect(realOpen.isActive)
    }

    @Test("既に締まっているデモセッションの時刻は書き換えない")
    func alreadyClosedDemoSessionsAreLeftAlone() throws {
        let context = try makeContext()
        let endedAt = Date(timeIntervalSince1970: 9_999)
        let done = insertSession(into: context, isDemo: true, endedAt: endedAt)

        #expect(DemoSessionStore.closeOpenDemoSessions(in: context) == 0)
        #expect(done.endedAt == endedAt)
    }
}
