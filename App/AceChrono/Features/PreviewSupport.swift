import AceChronoKit
import Foundation
import SwiftData

/// SwiftUI Preview 用の使い捨てデータ。
///
/// Preview でも `ReplayTransport` が動くので Live 画面は実際に値が流れる。
/// 履歴・詳細画面は静的なサンプルセッションを入れて確認する。
@MainActor
enum PreviewSupport {
    /// Preview の設定が実機の UserDefaults を汚さないよう、専用スイートを使う。
    static let defaults: UserDefaults = UserDefaults(suiteName: "acechrono.preview") ?? .standard

    static let container: ModelContainer = {
        let schema = Schema([Session.self, ShotRecord.self, GunProfile.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        // Preview 用のインメモリコンテナ。失敗したら Preview 自体が意味を成さないので落とす。
        guard let container = try? ModelContainer(for: schema, configurations: configuration) else {
            fatalError("Preview 用 ModelContainer を作成できません")
        }
        seed(into: container.mainContext)
        return container
    }()

    static func seed(into context: ModelContext) {
        let profile = GunProfile(name: "次世代 M4", bbWeightGrams: 0.25)
        context.insert(profile)

        let velocities: [[Double]] = [
            [91.2, 92.5, 90.8, 93.1, 91.7, 92.9, 90.1, 92.2],
            [88.4, 89.9, 87.6, 90.2, 88.8],
        ]
        for (index, group) in velocities.enumerated() {
            let start = Date().addingTimeInterval(-Double(index + 1) * 86_400)
            let session = Session(
                startedAt: start,
                endedAt: start.addingTimeInterval(Double(group.count) * 2),
                gunName: index == 0 ? "次世代 M4" : "ハンドガン",
                bbWeightGrams: index == 0 ? 0.25 : 0.20
            )
            context.insert(session)
            for (shotIndex, velocity) in group.enumerated() {
                let record = ShotRecord(
                    timestamp: start.addingTimeInterval(Double(shotIndex) * 1.7),
                    velocityMetersPerSecond: velocity,
                    rateOfFireRPS: nil,
                    session: session
                )
                context.insert(record)
                session.shots.append(record)
            }
        }
        try? context.save()
    }

    static var sampleSession: Session {
        let descriptor = FetchDescriptor<Session>()
        return (try? container.mainContext.fetch(descriptor))?.first
            ?? Session(gunName: "サンプル", bbWeightGrams: 0.25)
    }
}
