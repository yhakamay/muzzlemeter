import Foundation
import SwiftData

/// デモモードで作られたセッションの後始末。
///
/// **なぜ `ChronoService` の中ではなくここか。** デモの入り切りで一番怖いのは
/// 「デモを止めたのにデモのセッションが進行中のまま残る」「デモデータの削除で本物まで
/// 消える」の 2 つで、どちらも**保存層の操作の正しさ**の話。`ChronoService` は
/// `@MainActor` の `@Observable` で BLE・ライブアクティビティ・Watch まで抱えていて
/// テストから作れない。ストアに対する操作だけをここに切り出すと、SwiftData の
/// インメモリコンテナに対して `swift test` から直接検証できる
/// （`Tests/MuzzlemeterAppModelsTests`）。
enum DemoSessionStore {
    /// デモモードで作られたセッションを新しい順に返す。
    ///
    /// `#Predicate` ではなく取得後に絞るのは、履歴画面の絞り込み
    /// （`SessionsView.visibleSessions`）と同じ理由で、件数が高々数百だから。
    @MainActor
    static func demoSessions(in modelContext: ModelContext) -> [Session] {
        let descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\Session.startedAt, order: .reverse)]
        )
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.filter(\.isDemo)
    }

    /// デモのセッション数。設定の「デモデータを削除」を出すかどうかの判定に使う
    /// （1 件も無いのに破壊的なボタンを並べない）。
    @MainActor
    static func demoSessionCount(in modelContext: ModelContext) -> Int {
        demoSessions(in: modelContext).count
    }

    /// デモのセッションを**すべて**消す。実データには触らない。
    ///
    /// ショットは `Session.shots` の cascade で一緒に消える。消した件数を返す。
    @discardableResult
    @MainActor
    static func deleteDemoSessions(in modelContext: ModelContext) -> Int {
        let targets = demoSessions(in: modelContext)
        for session in targets {
            modelContext.delete(session)
        }
        if !targets.isEmpty { try? modelContext.save() }
        return targets.count
    }

    /// 開きっぱなしのデモセッションを閉じる。デモモードを切ったときに呼ぶ。
    ///
    /// `ChronoService.endSession()` は**いま自分が持っている**セッションしか閉じられない。
    /// 前回の起動の途中でデモのまま落ちた場合など、サービスが知らない開きっぱなしの
    /// デモセッションが残り得るので、切り替えのたびにストア側でも締める。
    /// 閉じた件数を返す。
    @discardableResult
    @MainActor
    static func closeOpenDemoSessions(in modelContext: ModelContext) -> Int {
        let open = demoSessions(in: modelContext).filter { $0.endedAt == nil }
        for session in open {
            // 最後のショットの時刻で閉じる（`ChronoService.closeSessionsLeftOpen` と同じ規則）。
            session.endedAt = session.orderedShots.last?.timestamp ?? session.startedAt
        }
        if !open.isEmpty { try? modelContext.save() }
        return open.count
    }
}
