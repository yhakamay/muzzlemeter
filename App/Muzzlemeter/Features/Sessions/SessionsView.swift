import MuzzlemeterKit
import SwiftData
import SwiftUI

/// 保存済みセッションの一覧。スワイプ削除・CSV 書き出し・比較モード。
struct SessionsView: View {
    @Environment(ChronoService.self) private var service
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Session.startedAt, order: .reverse) private var sessions: [Session]

    @State private var renamingSession: Session?
    /// 詳細への遷移を値で表す。目視確認の起動引数から最新セッションを開くために、
    /// `NavigationLink` の見た目だけの遷移ではなく**プログラムから積める形**にしてある。
    @State private var path = NavigationPath()

    /// 比較モード。ON の間は行が選択用になり、通常の遷移は止まる。
    @State private var isSelecting = false
    /// 選んだ順に持つ。**順番が色と表の並びになる**ので、`Set` ではなく配列。
    @State private var selected: [Session] = []

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
                    list
                }
            }
            .navigationDestination(for: Session.self) { session in
                SessionDetailView(session: session)
            }
            .navigationDestination(for: SessionComparisonRequest.self) { request in
                SessionComparisonView(sessions: request.sessions)
            }
            .task {
                // 目視確認用（Debug のシミュレータのみ）。いちばん新しいセッションを開く。
                if ScreenshotSupport.opensLatestSession, let latest = sessions.first {
                    path.append(latest)
                }
                if ScreenshotSupport.opensComparison,
                   let request = SessionComparisonRequest(
                       // 起動と同時に再生が始まって作られるセッションは外す
                       // （見本として入れたセッションを押しのけてしまうため）。
                       Array(sessions.filter { $0.startedAt < ScreenshotSupport.launchedAt }
                           .prefix(SessionComparisonRequest.range.upperBound))
                   ) {
                    path.append(request)
                }
            }
            .sessionRenameAlert(target: $renamingSession)
            .navigationTitle("履歴")
            .safeAreaInset(edge: .bottom) {
                if isSelecting { compareBar }
            }
            .toolbar { toolbarContent }
        }
    }

    private var list: some View {
        List {
            ForEach(sessions) { session in
                row(for: session)
                    // 比較モードの間は削除させない。選ぶつもりのスワイプで消えては困る。
                    .deleteDisabled(isSelecting)
            }
            .onDelete(perform: delete)
        }
    }

    @ViewBuilder
    private func row(for session: Session) -> some View {
        if isSelecting {
            SessionSelectionRow(
                session: session,
                speedUnit: service.speedUnit,
                isSelected: isSelected(session),
                isSelectable: isSelected(session)
                    || selected.count < SessionComparisonRequest.range.upperBound
            ) {
                toggle(session)
            }
        } else {
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
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("キャンセル") { endSelecting() }
            }
        } else if sessions.count >= SessionComparisonRequest.range.lowerBound {
            ToolbarItem(placement: .topBarLeading) {
                Button("比較", systemImage: "chart.line.uptrend.xyaxis") {
                    withAnimation(.snappy) { isSelecting = true }
                }
            }
        }
        if !sessions.isEmpty && !isSelecting {
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

    /// 比較モードの下部バー。**選べる件数の上限をその場に書く**。
    /// 4 件目を押しても何も起きない理由が分からないと、壊れていると思われる。
    private var compareBar: some View {
        VStack(spacing: 6) {
            Text("比べたいセッションを 2〜3 件選んでください（\(selected.count) / \(SessionComparisonRequest.range.upperBound)）")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                guard let request = SessionComparisonRequest(selected) else { return }
                isSelecting = false
                path.append(request)
            } label: {
                Text("比較する")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(SessionComparisonRequest(selected) == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func isSelected(_ session: Session) -> Bool {
        selected.contains { $0.persistentModelID == session.persistentModelID }
    }

    private func toggle(_ session: Session) {
        if let index = selected.firstIndex(where: { $0.persistentModelID == session.persistentModelID }) {
            selected.remove(at: index)
        } else if selected.count < SessionComparisonRequest.range.upperBound {
            selected.append(session)
        }
    }

    private func endSelecting() {
        withAnimation(.snappy) {
            isSelecting = false
            selected = []
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
