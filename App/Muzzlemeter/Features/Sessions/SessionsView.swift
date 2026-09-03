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

    /// 絞り込み条件（文字検索・タグ・銃）。
    ///
    /// SwiftData の述語ではなく**取得済みの配列に当てる**。件数は高々数百で、
    /// タグは 1 列の文字列なので `#Predicate` には落としづらく、
    /// 判定を `MuzzlemeterKit.SessionFilter` に置いたほうがテストできる。
    @State private var filter = SessionFilter()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "まだセッションがありません",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Live 画面で 1 発撃つと自動的にセッションが始まります。")
                    )
                } else if visibleSessions.isEmpty {
                    // 「消えた」のではなく「絞られている」ことと、戻しかたを同じ場所に出す。
                    ContentUnavailableView {
                        Label("条件に合うセッションがありません", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("タグ・銃・検索語のどれかを外すと戻ります。")
                    } actions: {
                        Button("絞り込みを解除") { withAnimation(.snappy) { filter.clear() } }
                    }
                } else {
                    list
                }
            }
            .searchable(
                text: $filter.searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: Text("タイトル・メモ・タグを検索")
            )
            .safeAreaInset(edge: .top) {
                if !sessions.isEmpty && !isSelecting { filterBar }
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
                if let tag = ScreenshotSupport.filterTag {
                    filter.tags = [tag]
                }
                if ScreenshotSupport.opensTagEditor,
                   let seeded = sessions.first(where: { $0.startedAt < ScreenshotSupport.launchedAt }) {
                    path.append(seeded)
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
            // 絞り込みの帯を上に貼り付けると、大きいタイトルの居場所と食い違って
            // 「履歴」が消える。帯は常に見えていてほしい（いま何で絞っているかは、
            // スクロールしても分からなくなってはいけない）ので、タイトルを畳む。
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if isSelecting { compareBar }
            }
            .toolbar { toolbarContent }
        }
    }

    private var list: some View {
        List {
            ForEach(visibleSessions) { session in
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
        } else if visibleSessions.count >= SessionComparisonRequest.range.lowerBound {
            ToolbarItem(placement: .topBarLeading) {
                Button("比較", systemImage: "chart.line.uptrend.xyaxis") {
                    withAnimation(.snappy) { isSelecting = true }
                }
            }
        }
        if !sessions.isEmpty && !isSelecting {
            ToolbarItem(placement: .topBarTrailing) {
                // 絞り込んでいるときは**画面に出ているものだけ**を書き出す。
                // 画面と書き出しの中身が違うと、CSV を開いてから気づくことになる。
                ShareLink(
                    item: CSVFile(
                        name: CSVExporter.allSessionsFileName,
                        text: CSVExporter.csv(for: visibleSessions)
                    ),
                    preview: SharePreview(
                        filter.isActive
                            ? Text("絞り込んだセッションの CSV")
                            : Text("全セッションの CSV")
                    )
                ) {
                    Label(
                        filter.isActive ? "絞り込んだ結果を CSV 書き出し" : "全件を CSV 書き出し",
                        systemImage: "square.and.arrow.up"
                    )
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
        // 絞り込んでいる間は**画面に出ている並び**が対象。取得順で消すと、
        // 見えていない行が消える。
        let shown = visibleSessions
        for index in offsets where shown.indices.contains(index) {
            modelContext.delete(shown[index])
        }
        try? modelContext.save()
    }

    // MARK: - 絞り込み

    /// 条件に合うセッション。**1 回のパス**で作って、行からは触らない。
    private var visibleSessions: [Session] {
        guard filter.isActive else { return sessions }
        return sessions.filter {
            filter.matches(
                title: $0.displayTitle,
                notes: $0.manualNotes,
                tags: $0.tags,
                gunName: $0.gunName
            )
        }
    }

    /// これまでに使われたタグ（よく使う順）。
    private var allTags: [String] {
        SessionTags.used(in: sessions.map(\.tags))
    }

    /// 記録に出てくる銃の名前。プロファイルではなく**セッションに残っている名前**で
    /// 絞る（プロファイルを消した銃の記録も絞り込めるようにするため）。
    private var gunNames: [String] {
        Array(Set(sessions.map(\.gunName))).sorted()
    }

    /// タグ・銃・解除をまとめた 1 本の帯。検索欄は `.searchable` が出す。
    private var filterBar: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    if gunNames.count > 1 {
                        Menu {
                            Picker("銃", selection: $filter.gunName) {
                                Text("すべての銃").tag(String?.none)
                                ForEach(gunNames, id: \.self) { name in
                                    Text(verbatim: name).tag(String?.some(name))
                                }
                            }
                        } label: {
                            TagChip(
                                text: filter.gunName ?? String(localized: "すべての銃"),
                                isSelected: filter.gunName != nil
                            )
                        }
                    }
                    ForEach(allTags, id: \.self) { tag in
                        TagChip(
                            text: tag,
                            isSelected: SessionTags.contains(tag, in: filter.tags),
                            action: { withAnimation(.snappy) { filter.toggle(tag: tag) } }
                        )
                    }
                    if filter.isActive {
                        Button("解除", systemImage: "xmark.circle") {
                            withAnimation(.snappy) { filter.clear() }
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            Divider()
        }
        .background(.bar)
        // タグも銃も 1 種類しか無いうちは、帯を出しても選ぶものが無い。
        .opacity(allTags.isEmpty && gunNames.count <= 1 ? 0 : 1)
        .frame(height: allTags.isEmpty && gunNames.count <= 1 ? 0 : nil)
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
            // 項目が多いので、行が足りなければ**項目ごと**次の行へ落とす。
            // 素の HStack だと「グロック 18C」のような 1 項目の途中で折り返す。
            FlowLayout(spacing: 10) {
                // 自動タイトルには日時と銃名が入っているので、見出しに出ていない情報だけを添える。
                if session.hasCustomTitle {
                    // 行が狭いので日付だけ（時刻は詳細で見られる）。時刻まで出すと
                    // 銃名・重量・平均が押し出されて折り返し、1 行で読めなくなる。
                    Text(session.startedAt, format: .dateTime.month().day())
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

            // タグは行の一番下。数字（発数・平均）より優先度が低く、
            // かつ**折り返す可能性がある**ので、他の行を押し下げない位置に置く。
            if !session.tags.isEmpty {
                TagChipRow(tags: session.tags)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    SessionsView()
        .environment(ChronoService(defaults: PreviewSupport.defaults, forceReplay: true))
        .modelContainer(PreviewSupport.container)
}
