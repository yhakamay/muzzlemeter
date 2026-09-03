import ShotLogKit
import Charts
import SwiftData
import SwiftUI

/// セッション詳細。速度推移のチャート（平均線・±SD 帯）と全ショット表。
struct SessionDetailView: View {
    let session: Session
    @Environment(ChronoService.self) private var service

    @State private var renamingSession: Session?
    @State private var isEditingEnvironment = false

    var body: some View {
        let shots = session.orderedShots
        let stats = session.stats

        List {
            Section("銃") {
                LabeledContent("名前", value: session.gunName)
                if let makeAndModel = session.gunMakeAndModel {
                    LabeledContent("メーカー / モデル", value: makeAndModel)
                }
                if let category = session.gunPowerCategory {
                    LabeledContent("パワーソース") {
                        PowerCategoryBadge(category: category)
                    }
                }
                if let barrel = session.gunInnerBarrelLengthMm {
                    LabeledContent("インナーバレル長", value: "\(barrel) mm")
                }
            }

            // 「その回の条件」。統計とジュールはすべてこの値で計算されているので、
            // 銃の仕様とは別のまとまりとして、数字より先に読める位置に置く。
            Section {
                LabeledContent("BB 重量", value: GunProfile.weightLabel(session.bbWeightGrams))
                if let gasType = session.gasType {
                    LabeledContent("ガス種別", value: gasType.label)
                }
                if !session.hopSetting.isEmpty {
                    LabeledContent("ホップ", value: session.hopSetting)
                }
                LabeledContent(
                    "規制上限",
                    value: GunProfile.energyLimitLabel(session.energyLimitJoules)
                )
            } header: {
                HStack {
                    Text("セッション条件")
                    Spacer()
                    // 一瞥用の 1 行。Live 画面のピル直下に出ているものと同じ書式にして、
                    // 「あのとき見ていた条件」とそのまま突き合わせられるようにする。
                    Text(verbatim: session.variablesSummary)
                        .textCase(nil)
                }
            }

            SessionEnvironmentSection(session: session, isEditing: $isEditingEnvironment)

            Section {
                chart(shots: shots, stats: stats)
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 16))
            }

            // StatsCard 自身が「セッション統計」の見出しを持っているので、
            // Section 側に見出しを付けると同じ意味の行が 2 段重なる。
            Section {
                StatsCard(
                    stats: stats,
                    speedUnit: service.speedUnit,
                    rateOfFireUnit: service.rateOfFireUnit,
                    fallbackRateOfFireRPS: RateOfFire.estimateRPS(shots: session.domainShots),
                    energyLimitJoules: session.energyLimitJoules,
                    overLimitCount: EnergyLimit.overLimitCount(
                        shots: session.domainShots,
                        massGrams: session.bbWeightGrams,
                        limitJoules: session.energyLimitJoules
                    )
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                .listRowBackground(Color.clear)
            }

            Section("ショット") {
                ForEach(Array(shots.enumerated()), id: \.element.persistentModelID) { index, shot in
                    let margin = EnergyLimit.margin(
                        joules: shot.joules(massGrams: session.bbWeightGrams),
                        limitJoules: session.energyLimitJoules
                    )
                    HStack {
                        Text(verbatim: "\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 32, alignment: .leading)
                        Text(service.speedUnit.formatted(metersPerSecond: shot.velocityMetersPerSecond))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(margin.tint ?? .primary)
                        if margin.isOver {
                            Image(systemName: margin.symbolName)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .accessibilityLabel(Text("超過"))
                        }
                        Spacer()
                        Text(JouleFormat.labeled(shot.joules(massGrams: session.bbWeightGrams)))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(margin.tint ?? .secondary)
                        Text(shot.timestamp, format: .dateTime.hour().minute().second())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 8)   // ジュール値と時刻がくっつかないように
                    }
                }
            }
        }
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sessionRenameAlert(target: $renamingSession)
        .sheet(isPresented: $isEditingEnvironment) {
            SessionEnvironmentEditor(session: session)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("名前を変更", systemImage: "pencil") {
                    renamingSession = session
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(
                    item: CSVFile(
                        name: CSVExporter.fileName(for: session),
                        text: CSVExporter.csv(for: session)
                    ),
                    preview: SharePreview("このセッションの CSV")
                ) {
                    Label("CSV 書き出し", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    // MARK: - チャート

    @ViewBuilder
    private func chart(shots: [ShotRecord], stats: SessionStats) -> some View {
        let unit = service.speedUnit
        let values = shots.enumerated().map { index, shot in
            (
                index: index + 1,
                value: unit.value(fromMetersPerSecond: shot.velocityMetersPerSecond),
                margin: EnergyLimit.margin(
                    joules: shot.joules(massGrams: session.bbWeightGrams),
                    limitJoules: session.energyLimitJoules
                )
            )
        }
        // 規制上限は J だが、チャートの縦軸は速度。同じ BB 重量で上限ちょうどになる
        // 初速へ**換算して**引く（E = ½mv² を v について解く）。
        //
        // ただし**データから極端に離れているときは引かない**。縦軸は `includesZero: false`
        // でデータの範囲だけを取っているので、遠い上限を混ぜると実測のばらつきが
        // 一本の線に潰れて、チャート本来の用途（散らばりを見る）が壊れる。
        let limitSpeed = EnergyLimit
            .maxVelocity(massGrams: session.bbWeightGrams, limitJoules: session.energyLimitJoules)
            .map { unit.value(fromMetersPerSecond: $0) }
            .flatMap { limit -> Double? in
                guard let maxValue = values.map(\.value).max(),
                      let minValue = values.map(\.value).min()
                else { return nil }
                return (limit <= maxValue * 1.15 && limit >= minValue * 0.5) ? limit : nil
            }
        let mean = stats.meanMetersPerSecond.map { unit.value(fromMetersPerSecond: $0) }
        // SD は「差」なので、fps 換算では比率だけを掛ける（オフセットの無い線形変換）。
        let sd = stats.sampleStandardDeviation.map {
            unit.value(fromMetersPerSecond: $0) - unit.value(fromMetersPerSecond: 0)
        }

        if values.isEmpty {
            ContentUnavailableView("ショットがありません", systemImage: "chart.xyaxis.line")
        } else {
            Chart {
                if let mean, let sd {
                    RectangleMark(
                        yStart: .value(String(localized: "−SD"), mean - sd),
                        yEnd: .value(String(localized: "+SD"), mean + sd)
                    )
                    .foregroundStyle(.blue.opacity(0.12))
                }
                if let mean {
                    RuleMark(y: .value(String(localized: "平均"), mean))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            // データ線と重なると読めなくなるので、地の色を敷いて浮かせる。
                            Text("平均 \(unit.format(metersPerSecond: stats.meanMetersPerSecond ?? 0)) \(unit.symbol)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.background, in: .rect(cornerRadius: 4))
                        }
                }
                // 規制上限の線。データ線より**上**に描かれるよう、点より先に置く。
                if let limitSpeed {
                    RuleMark(y: .value(String(localized: "規制上限"), limitSpeed))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .foregroundStyle(.red.opacity(0.7))
                        .annotation(position: .bottom, alignment: .trailing, spacing: 2) {
                            Text("上限 \(GunProfile.energyLimitLabel(session.energyLimitJoules))")
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.background, in: .rect(cornerRadius: 4))
                        }
                }
                ForEach(values, id: \.index) { point in
                    LineMark(
                        x: .value(String(localized: "発"), point.index),
                        y: .value(String(localized: "速度"), point.value)
                    )
                    .foregroundStyle(.blue)
                    // 越えた 1 発だけ赤くする。線は繋がったままなので「どこで越えたか」が
                    // 形として読める。
                    PointMark(
                        x: .value(String(localized: "発"), point.index),
                        y: .value(String(localized: "速度"), point.value)
                    )
                    .symbolSize(point.margin.isOver ? 60 : 24)
                    .foregroundStyle(point.margin.chartTint)
                }
            }
            // 既定だと Y 軸が 0 を含むため、90 m/s 前後のばらつきが一本の直線に潰れる。
            // 見たいのは「どれだけ散っているか」なので、データの範囲だけを取る。
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxisLabel(unit.symbol)
            .chartXAxisLabel { Text("発目") }
        }
    }
}

#Preview {
    NavigationStack {
        SessionDetailView(session: PreviewSupport.sampleSession)
    }
    .environment(ChronoService(defaults: PreviewSupport.defaults, forceReplay: true))
    .modelContainer(PreviewSupport.container)
}
