import ShotLogKit
import SwiftData
import SwiftUI

/// 保存済みセッションの一覧。スワイプ削除と CSV 書き出し。
struct SessionsView: View {
    @Environment(ChronoService.self) private var service
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Session.startedAt, order: .reverse) private var sessions: [Session]

    @State private var renamingSession: Session?
    /// 詳細への遷移を値で表す。目視確認の起動引数から最新セッションを開くために、
    /// `NavigationLink` の見た目だけの遷移ではなく**プログラムから積める形**にしてある。
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "まだセッションがありません",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Live 画面で 1 発撃つと自動的にセッションが始まります。")
                    )
                } else {
                    List {
                        ForEach(sessions) { session in
                            NavigationLink(value: session) {
                                SessionRow(session: session, speedUnit: service.speedUnit)
                            }
                            // 名前の変更は破壊的ではないので leading（右スワイプ）に置く。
                            // 削除は onDelete（左スワイプ）のまま。
                            .swipeActions(edge: .leading) {
                                Button("名前を変更", systemImage: "pencil") {
                                    renamingSession = session
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button("名前を変更", systemImage: "pencil") {
                                    renamingSession = session
                                }
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationDestination(for: Session.self) { session in
                SessionDetailView(session: session)
            }
            .task {
                // 目視確認用（Debug のシミュレータのみ）。いちばん新しいセッションを開く。
                if ScreenshotSupport.opensLatestSession, let latest = sessions.first {
                    path.append(latest)
                }
            }
            .sessionRenameAlert(target: $renamingSession)
            .navigationTitle("履歴")
            .toolbar {
                if !sessions.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(
                            item: CSVFile(
                                name: CSVExporter.allSessionsFileName,
                                text: CSVExporter.csv(for: sessions)
                            ),
                            preview: SharePreview("全セッションの CSV")
                        ) {
                            Label("全件を CSV 書き出し", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(sessions[index])
        }
        try? modelContext.save()
    }
}

struct SessionRow: View {
    let session: Session
    let speedUnit: SpeedUnit

    var body: some View {
        let stats = session.stats
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                if session.isActive {
                    Text("進行中")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: .capsule)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text("\(stats.count) 発")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                // 自動タイトルには日時と銃名が入っているので、見出しに出ていない情報だけを添える。
                if session.hasCustomTitle {
                    Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                    Text(session.gunName)
                }
                Text(GunProfile.weightLabel(session.bbWeightGrams))
                if let mean = stats.meanMetersPerSecond {
                    Text("平均 \(speedUnit.formatted(metersPerSecond: mean))")
                }
                if let joules = stats.meanJoules {
                    Text(JouleFormat.labeled(joules))
                }
                if let temperature = session.temperatureC {
                    Text(verbatim: EnvironmentFormat.compactTemperature(temperature))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    SessionsView()
        .environment(ChronoService(defaults: PreviewSupport.defaults, forceReplay: true))
        .modelContainer(PreviewSupport.container)
}
