import MuzzlemeterKit
import Charts
import SwiftData
import SwiftUI

/// 比較する 2〜3 セッションを指す値。`NavigationPath` に積めるようにしてある。
///
/// 画面そのものを push するのではなく**値で遷移する**のは、履歴一覧の選択モードと
/// セッション詳細の「他のセッションと比較」という 2 つの入口から、同じ遷移先を
/// 同じ形で組み立てられるようにするため。
struct SessionComparisonRequest: Hashable {
    let sessions: [Session]

    /// 比較として成立する件数（2〜3 件）。
    static let range = 2...3

    init?(_ sessions: [Session]) {
        guard Self.range.contains(sessions.count) else { return nil }
        self.sessions = sessions
    }
}

/// セッション比較。ヘッダ（色見本）・統計表・重ね合わせチャート・要約チャート。
struct SessionComparisonView: View {
    @Environment(ChronoService.self) private var service

    /// 統計は**開いたときに 1 回だけ**計算して持つ。行とチャートで同じ値を何度も読むので、
    /// ビューの body で計算し直すと発数に比例して無駄が増える（数百発 × 3 セッション）。
    @State private var entries: [SessionComparisonEntry]
    @State private var showsMeanRules = true

    init(sessions: [Session]) {
        _entries = State(initialValue: SessionComparisonEntry.make(from: sessions))
    }

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    header(entry)
                }
            } header: {
                Text("比べているセッション")
            }

            Section {
                statsTable
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            } header: {
                Text("統計")
            } footer: {
                // 何にでも印を付けると「印のほうを選べばよい」と誤読させる。
                // 向きのある項目だけに印を付けている理由を明示する。
                Text("印は「小さいほうが良い」項目（SD・ES・超過発数）にだけ付きます。平均や最大は速ければ良いというものではないので、印を付けていません。")
            }

            Section {
                overlayChart
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 4, trailing: 16))
                Toggle("平均線を出す", isOn: $showsMeanRules)
                    .font(.footnote)
            } header: {
                Text("弾速の重ね合わせ")
            } footer: {
                Text("横軸は各セッションの何発目か。発数が違っても、立ち上がりからの動きかたを重ねて見られます。")
            }

            Section {
                summaryChart
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 16))
            } header: {
                Text("ばらつきの要約")
            } footer: {
                Text("細い縦線が最小〜最大、太い帯が平均 ±SD、点が平均です。帯が細いほど安定しています。")
            }
        }
        .navigationTitle("セッション比較")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(
                    item: CSVFile(
                        name: CSVExporter.allSessionsFileName,
                        text: CSVExporter.csv(for: entries.map(\.session))
                    ),
                    preview: SharePreview("比較したセッションの CSV")
                ) {
                    Label("CSV で共有", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    // MARK: - ヘッダ

    private func header(_ entry: SessionComparisonEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // 色見本はチャートの線の色と同じ。表とチャートを行き来するときの手掛かり。
            RoundedRectangle(cornerRadius: 3)
                .fill(entry.color)
                .frame(width: 10, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(entry.gunName)
                    Text(GunProfile.weightLabel(entry.bbWeightGrams))
                    Text(entry.startedAt, format: .dateTime.year().month().day().hour().minute())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                // 「何を試した回か」はタグに書いてあることが多い。比較の見出しに
                // 出しておかないと、番号と銃名だけでどれがどれか思い出せない。
                if !entry.tags.isEmpty {
                    TagChipRow(tags: entry.tags)
                }
            }
            Spacer(minLength: 0)
            Text(verbatim: entry.shortLabel)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(entry.color)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 統計表

    private var statsTable: some View {
        let best = ComparisonTable.bestIndicesByMetric(columns: entries.map(\.column))
        return Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text(verbatim: "")
                    .gridColumnAlignment(.leading)
                ForEach(entries) { entry in
                    Text(verbatim: entry.shortLabel)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(entry.color)
                        // 値の列だけを伸ばして、表を画面幅いっぱいに散らす
                        // （項目名の列は文字の幅のまま）。
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            Divider()
                .gridCellUnsizedAxes(.horizontal)
            ForEach(ComparisonTable.metrics) { metric in
                let values = ComparisonTable.values(of: metric, columns: entries.map(\.column))
                GridRow {
                    Text(label(for: metric))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        cell(
                            metric: metric,
                            value: value,
                            isBest: best[metric]?.contains(index) == true,
                            isOverLimit: metric == .overLimitCount && (value ?? 0) > 0
                        )
                    }
                }
            }
        }
    }

    private func cell(
        metric: ComparisonMetric,
        value: Double?,
        isBest: Bool,
        isOverLimit: Bool
    ) -> some View {
        Text(verbatim: format(metric: metric, value: value))
            .font(.footnote.monospacedDigit().weight(isBest ? .bold : .regular))
            .foregroundStyle(isOverLimit ? .red : .primary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            // 印は色ではなく**薄い地色と太字**にしてある。色で表すと、規制上限の
            // 橙 / 赤（安全に直結する意味）と混ざって読めなくなる。
            .background(
                isBest ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.clear),
                in: .rect(cornerRadius: 5)
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel(Text(label(for: metric)))
            .accessibilityValue(
                Text(isBest
                     ? String(localized: "\(format(metric: metric, value: value))（この中で最も良い）")
                     : format(metric: metric, value: value))
            )
    }

    private func label(for metric: ComparisonMetric) -> String {
        switch metric {
        case .count: String(localized: "発数")
        case .mean: String(localized: "平均")
        case .sampleStandardDeviation: "SD"
        case .extremeSpread: "ES"
        case .max: String(localized: "最大")
        case .min: String(localized: "最小")
        case .meanJoules: String(localized: "平均 J")
        case .overLimitCount: String(localized: "超過発数")
        }
    }

    private func format(metric: ComparisonMetric, value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        switch metric.kind {
        case .shotCount: return String(format: "%.0f", value)
        case .joules: return JouleFormat.value(value)
        case .speed: return service.speedUnit.format(metersPerSecond: value)
        }
    }

    // MARK: - チャート

    /// 弾速の重ね合わせ。横軸は「何発目か」。
    private var overlayChart: some View {
        let unit = service.speedUnit
        return Chart {
            ForEach(entries) { entry in
                ForEach(entry.points) { point in
                    LineMark(
                        x: .value(String(localized: "発"), point.index),
                        y: .value(String(localized: "速度"), unit.value(fromMetersPerSecond: point.metersPerSecond)),
                        series: .value(String(localized: "セッション"), entry.shortLabel)
                    )
                    // 補間は既定の直線のまま。滑らかな曲線にすると、撃っていない
                    // 発と発の間に値があるように見えてしまう（詳細画面のチャートと同じ扱い）。
                    .foregroundStyle(entry.color)
                }
                if showsMeanRules, let mean = entry.stats.meanMetersPerSecond {
                    RuleMark(y: .value(String(localized: "平均"), unit.value(fromMetersPerSecond: mean)))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(entry.color.opacity(0.7))
                }
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxisLabel(unit.symbol)
        .chartXAxisLabel { Text("発目") }
        .chartLegend(.hidden)
        .accessibilityLabel(Text("弾速の重ね合わせ"))
    }

    /// 最小〜最大の縦線・平均 ±SD の帯・平均の点。箱ひげ図の代わり。
    ///
    /// Swift Charts に箱ひげ図のマークは無い。四分位を自前で出すこともできるが、
    /// このアプリの統計（SD / ES）と指標が食い違うと読み手が混乱するので、
    /// **画面の他の場所と同じ指標**（最小・最大・平均・SD）で組み立てる。
    private var summaryChart: some View {
        let unit = service.speedUnit
        return Chart {
            ForEach(entries) { entry in
                if let minV = entry.stats.minMetersPerSecond,
                   let maxV = entry.stats.maxMetersPerSecond {
                    BarMark(
                        x: .value(String(localized: "セッション"), entry.shortLabel),
                        yStart: .value(String(localized: "最小"), unit.value(fromMetersPerSecond: minV)),
                        yEnd: .value(String(localized: "最大"), unit.value(fromMetersPerSecond: maxV)),
                        width: .fixed(4)
                    )
                    .foregroundStyle(entry.color.opacity(0.35))
                }
                if let mean = entry.stats.meanMetersPerSecond,
                   let sd = entry.stats.sampleStandardDeviation {
                    BarMark(
                        x: .value(String(localized: "セッション"), entry.shortLabel),
                        yStart: .value(String(localized: "−SD"), unit.value(fromMetersPerSecond: mean - sd)),
                        yEnd: .value(String(localized: "+SD"), unit.value(fromMetersPerSecond: mean + sd)),
                        width: .fixed(32)
                    )
                    .foregroundStyle(entry.color.opacity(0.22))
                }
                if let mean = entry.stats.meanMetersPerSecond {
                    PointMark(
                        x: .value(String(localized: "セッション"), entry.shortLabel),
                        y: .value(String(localized: "平均"), unit.value(fromMetersPerSecond: mean))
                    )
                    .symbolSize(70)
                    .foregroundStyle(entry.color)
                }
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxisLabel(unit.symbol)
        .chartLegend(.hidden)
        .accessibilityLabel(Text("ばらつきの要約"))
    }
}

// MARK: - 1 セッション分の下ごしらえ

/// 比較画面が使う 1 セッション分の値。**開くときに 1 回だけ**作る。
struct SessionComparisonEntry: Identifiable {
    struct Point: Identifiable {
        let id: Int
        var index: Int { id }
        let metersPerSecond: Double
    }

    let id: PersistentIdentifier
    let session: Session
    let color: Color
    /// 表の見出しとチャートの系列名に使う短い番号（`1` / `2` / `3`）。
    let shortLabel: String
    let title: String
    let gunName: String
    let bbWeightGrams: Double
    let startedAt: Date
    let tags: [String]
    let stats: SessionStats
    let column: ComparisonColumn
    let points: [Point]

    /// セッションの色。**橙と赤は使わない**。規制上限の「注意 / 超過」で意味が
    /// 決まっている色なので、系列の識別に使うと安全の合図と混ざる。
    static let palette: [Color] = [.blue, .purple, .teal]

    static func make(from sessions: [Session]) -> [SessionComparisonEntry] {
        sessions.enumerated().map { index, session in
            let shots = session.domainShots
            let stats = SessionStats.compute(shots: shots, massGrams: session.bbWeightGrams)
            return SessionComparisonEntry(
                id: session.persistentModelID,
                session: session,
                color: palette[index % palette.count],
                shortLabel: "\(index + 1)",
                title: session.displayTitle,
                gunName: session.gunName,
                bbWeightGrams: session.bbWeightGrams,
                startedAt: session.startedAt,
                tags: session.tags,
                stats: stats,
                column: ComparisonColumn(
                    id: String(describing: session.persistentModelID),
                    stats: stats,
                    overLimitCount: EnergyLimit.overLimitCount(
                        shots: shots,
                        massGrams: session.bbWeightGrams,
                        limitJoules: session.energyLimitJoules
                    )
                ),
                points: shots.enumerated().map { Point(id: $0.offset + 1, metersPerSecond: $0.element.velocityMetersPerSecond) }
            )
        }
    }
}

#Preview {
    NavigationStack {
        SessionComparisonView(sessions: PreviewSupport.comparableSessions)
    }
    .environment(ChronoService(defaults: PreviewSupport.defaults, forceReplay: true))
    .modelContainer(PreviewSupport.container)
}
