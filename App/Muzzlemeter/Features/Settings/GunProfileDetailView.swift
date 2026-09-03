import MuzzlemeterKit
import Charts
import SwiftData
import SwiftUI

/// プロファイルの詳細。仕様と既定値に加えて、**そのプロファイルで撃った記録の推移**を出す。
///
/// 設定の一覧から直接編集シートを開いていたが、それだと「この銃はいまどうなっているか」
/// を見る場所が無かった。編集はここからさらに 1 段（`編集`）に置き、
/// 画面そのものは**読むためのもの**にしてある。
struct GunProfileDetailView: View {
    let profile: GunProfile

    @Environment(ChronoService.self) private var service
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Session.startedAt, order: .reverse) private var allSessions: [Session]

    @State private var isEditing = false
    /// タップされた点のセッション。`navigationDestination(item:)` で押し込む。
    @State private var selectedSession: Session?

    var body: some View {
        List {
            summarySection
            trendSection
            temperatureSection
            specSection
        }
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedSession) { session in
            SessionDetailView(session: session)
        }
        .sheet(isPresented: $isEditing) {
            GunProfileEditor(profile: profile) { draft in
                draft.apply(to: profile)
                try? modelContext.save()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("編集") { isEditing = true }
            }
        }
    }

    // MARK: - まとめ

    private var summarySection: some View {
        Section {
            LabeledContent("セッション数", value: "\(summary.sessionCount)")
            LabeledContent("合計発数", value: "\(summary.shotCount)")
            if let last = summary.lastSessionDate {
                LabeledContent("最後のセッション") {
                    Text(last, format: .dateTime.year().month().day())
                }
            }
            if let mean = summary.meanMetersPerSecond {
                LabeledContent("平均", value: service.speedUnit.formatted(metersPerSecond: mean))
            }
            if let sd = summary.sampleStandardDeviation {
                LabeledContent("SD", value: sdText(sd))
            }
        } header: {
            Text("これまで")
        } footer: {
            // 「セッションごとの SD を平均したもの」だと思われないように書いておく。
            Text("平均と SD は、このプロファイルで撃った全ショットをまとめて 1 つの標本として計算しています。")
        }
    }

    // MARK: - 平均弾速の推移

    @ViewBuilder
    private var trendSection: some View {
        Section {
            if points.isEmpty {
                ContentUnavailableView(
                    "まだ記録がありません",
                    systemImage: "chart.xyaxis.line",
                    description: Text("このプロファイルで 1 発でも撃つと、ここに推移が出ます。")
                )
            } else {
                trendChart
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 16))
            }
        } header: {
            Text("平均弾速の推移")
        } footer: {
            if !points.isEmpty {
                Text("点が 1 セッションの平均、縦の線が ±SD（そのセッションのばらつき）です。点をタップするとそのセッションを開きます。")
            }
        }
    }

    private var trendChart: some View {
        let unit = service.speedUnit
        return Chart {
            ForEach(points) { point in
                // ±SD の縦線。点だけだと「その回どれだけ散っていたか」が消える。
                RuleMark(
                    x: .value(String(localized: "日付"), point.date),
                    yStart: .value(String(localized: "−SD"), unit.value(fromMetersPerSecond: point.lowerMetersPerSecond)),
                    yEnd: .value(String(localized: "+SD"), unit.value(fromMetersPerSecond: point.upperMetersPerSecond))
                )
                .lineStyle(StrokeStyle(lineWidth: 5, lineCap: .round))
                .foregroundStyle(by: .value(String(localized: "BB 重量"), weightLabel(point)))
                .opacity(0.25)

                LineMark(
                    x: .value(String(localized: "日付"), point.date),
                    y: .value(String(localized: "平均"), unit.value(fromMetersPerSecond: point.meanMetersPerSecond))
                )
                .foregroundStyle(by: .value(String(localized: "BB 重量"), weightLabel(point)))

                PointMark(
                    x: .value(String(localized: "日付"), point.date),
                    y: .value(String(localized: "平均"), unit.value(fromMetersPerSecond: point.meanMetersPerSecond))
                )
                .symbolSize(60)
                .foregroundStyle(by: .value(String(localized: "BB 重量"), weightLabel(point)))
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxisLabel(unit.symbol)
        // BB 重量が 1 種類しか無いなら凡例は情報を持たない（同じことを 2 回言うだけ）。
        .chartLegend(massVaries ? .visible : .hidden)
        .chartForegroundStyleScale(range: Self.weightColors)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(.rect)
                    .onTapGesture { location in
                        select(at: location, proxy: proxy, geometry: geometry)
                    }
            }
        }
        .accessibilityLabel(Text("平均弾速の推移"))
    }

    /// タップ位置に**いちばん近い**セッションを開く。
    ///
    /// 点そのものを押させると、指の大きさに対して当たり判定が小さすぎる。
    /// 横位置（日付）だけで最も近い点を選ぶ。
    private func select(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let x = location.x - geometry[plotFrame].origin.x
        guard let date: Date = proxy.value(atX: x),
              let point = ProfileTrend.nearestPoint(to: date, in: points),
              let session = sessionsByID[point.id]
        else { return }
        selectedSession = session
    }

    // MARK: - 気温との関係

    @ViewBuilder
    private var temperatureSection: some View {
        let scatter = ProfileTrend.temperaturePoints(points)
        if !scatter.isEmpty {
            Section {
                temperatureChart(scatter)
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 16))
            } header: {
                Text("気温との関係")
            } footer: {
                if scatter.count < ProfileTrend.minimumTemperaturePoints {
                    // 2 点は必ず直線に見える。傾きを読み取られる前に断る。
                    Text("気温が記録されているセッションが \(scatter.count) 件しかありません。傾きを読み取るには \(ProfileTrend.minimumTemperaturePoints) 件以上ほしいところです。")
                } else {
                    Text("気温が記録されているセッションだけを出しています。ガス銃は気温で初速が大きく動きます。")
                }
            }
        }
    }

    private func temperatureChart(_ scatter: [ProfileTrendPoint]) -> some View {
        let unit = service.speedUnit
        return Chart(scatter) { point in
            PointMark(
                x: .value(String(localized: "気温"), point.temperatureC ?? 0),
                y: .value(String(localized: "平均"), unit.value(fromMetersPerSecond: point.meanMetersPerSecond))
            )
            .symbolSize(80)
            .foregroundStyle(by: .value(String(localized: "BB 重量"), weightLabel(point)))
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXScale(domain: .automatic(includesZero: false))
        .chartYAxisLabel(unit.symbol)
        .chartXAxisLabel { Text("℃") }
        .chartLegend(massVaries ? .visible : .hidden)
        .chartForegroundStyleScale(range: Self.weightColors)
        .accessibilityLabel(Text("気温と平均弾速の散布図"))
    }

    // MARK: - 仕様

    private var specSection: some View {
        Section {
            if let makeAndModel = profile.makeAndModel {
                LabeledContent("メーカー / モデル", value: makeAndModel)
            }
            LabeledContent("パワーソース") {
                PowerCategoryBadge(category: profile.powerCategory)
            }
            if let barrel = profile.innerBarrelLengthMm {
                LabeledContent("インナーバレル長", value: "\(barrel) mm")
            }
            LabeledContent("規制上限", value: GunProfile.energyLimitLabel(profile.energyLimitJoules))
            LabeledContent(
                "BB 重量の既定値",
                value: GunProfile.weightLabel(profile.defaultBBWeightGrams)
            )
            if profile.powerCategory.usesGas {
                LabeledContent("ガス種別の既定値", value: profile.defaultGasType.label)
            }
            if !profile.defaultHopSetting.isEmpty {
                LabeledContent("ホップの既定値", value: profile.defaultHopSetting)
            }
            if let target = ShotTarget(profile.targetShotCount) {
                LabeledContent("目標発数", value: "\(target.count) 発")
            }
            if !profile.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("メモ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: profile.notes)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("この銃の設定")
        }
    }

    // MARK: - データ

    /// このプロファイルのセッション。**セッションに記録された銃名**で結び付ける。
    ///
    /// セッションはプロファイルを参照せず値をコピーしている（過去の記録が
    /// 後からの編集で変わってはいけないため）。その代わり、プロファイル名を変えると
    /// それ以前のセッションはここに出てこなくなる。名前は銃の同一性そのものなので、
    /// 参照を持たせるより副作用が小さいと判断した。
    private var sessions: [Session] {
        allSessions.filter { $0.gunName == profile.name }
    }

    private var samples: [ProfileTrendSample] {
        sessions.map { session in
            ProfileTrendSample(
                id: String(describing: session.persistentModelID),
                date: session.startedAt,
                massGrams: session.bbWeightGrams,
                temperatureC: session.temperatureC,
                stats: session.stats
            )
        }
    }

    /// 統計は 1 回のパスで作る。チャート 2 つとまとめで同じ値を使う。
    private var points: [ProfileTrendPoint] { ProfileTrend.points(from: samples) }
    private var summary: ProfileTrendSummary { ProfileTrend.summary(from: samples) }
    private var massVaries: Bool { ProfileTrend.massGramsVaries(points) }

    private var sessionsByID: [String: Session] {
        Dictionary(
            sessions.map { (String(describing: $0.persistentModelID), $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// 系列名（＝凡例の見出し）。重量が 1 種類しか無いときも同じキーで通す。
    private func weightLabel(_ point: ProfileTrendPoint) -> String {
        GunProfile.weightLabel(point.massGrams)
    }

    /// BB 重量ごとの色。橙・赤は規制上限の意味で使っているので避ける。
    private static let weightColors: [Color] = [.blue, .purple, .teal, .indigo, .mint]

    /// SD は「差」なので、fps 換算では比率だけを掛ける（オフセットを持たない）。
    private func sdText(_ sd: Double) -> String {
        let unit = service.speedUnit
        let converted = unit.value(fromMetersPerSecond: sd) - unit.value(fromMetersPerSecond: 0)
        return String(format: "%.\(unit.fractionDigits)f %@", converted, unit.symbol)
    }
}

#Preview {
    NavigationStack {
        GunProfileDetailView(profile: PreviewSupport.sampleProfile)
    }
    .environment(ChronoService(defaults: PreviewSupport.defaults, forceReplay: true))
    .modelContainer(PreviewSupport.container)
}
