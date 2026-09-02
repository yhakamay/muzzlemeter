import AceChronoKit
import SwiftData
import SwiftUI

/// 保存済みセッションの一覧。スワイプ削除と CSV 書き出し。
struct SessionsView: View {
    @Environment(ChronoService.self) private var service
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Session.startedAt, order: .reverse) private var sessions: [Session]

    var body: some View {
        NavigationStack {
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
                            NavigationLink {
                                SessionDetailView(session: session)
                            } label: {
                                SessionRow(session: session, speedUnit: service.speedUnit)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
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
                Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(.headline)
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
                Text(session.gunName)
                Text(GunProfile.weightLabel(session.bbWeightGrams))
                if let mean = stats.meanMetersPerSecond {
                    Text("平均 \(speedUnit.formatted(metersPerSecond: mean))")
                }
                if let joules = stats.meanJoules {
                    Text(JouleFormat.labeled(joules))
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
