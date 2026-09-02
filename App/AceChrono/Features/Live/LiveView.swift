import AceChronoKit
import SwiftData
import SwiftUI

/// 起動時の画面。UX 原則「射撃中は片手・一瞥で読めること」。
///
/// 上から: 接続ピル / 直近弾速（超大文字）/ ジュール・プロファイル / 統計カード / 直近 10 発。
struct LiveView: View {
    @Environment(ChronoService.self) private var service
    @Query(sort: \GunProfile.createdAt) private var profiles: [GunProfile]

    var body: some View {
        @Bindable var service = service

        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    ConnectionPill(state: service.connectionState, isReplaying: service.isReplaying)

                    lastVelocity

                    StatsCard(
                        stats: service.stats,
                        speedUnit: service.speedUnit,
                        rateOfFireUnit: service.rateOfFireUnit,
                        fallbackRateOfFireRPS: service.displayRateOfFireRPS
                    )

                    recentShots
                }
                .padding()
            }
            .navigationTitle("Live")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("銃プロファイル", selection: $service.selectedProfile) {
                            ForEach(profiles) { profile in
                                Text("\(profile.name)  \(GunProfile.weightLabel(profile.bbWeightGrams))")
                                    .tag(Optional(profile))
                            }
                        }
                    } label: {
                        Label(service.gunName, systemImage: "scope")
                            .labelStyle(.titleAndIcon)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("セッションを終了して保存", systemImage: "checkmark.circle") {
                            service.endSession()
                        }
                        .disabled(service.currentShots.isEmpty)
                        Button("このセッションを破棄", systemImage: "trash", role: .destructive) {
                            service.discardSession()
                        }
                        .disabled(service.currentShots.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    // MARK: - 直近弾速

    private var lastVelocity: some View {
        VStack(spacing: 6) {
            if let shot = service.lastShot {
                Text(service.formattedSpeed(shot.velocityMetersPerSecond))
                    .font(.system(size: 88, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: shot.velocityMetersPerSecond)
                Text(service.speedUnit.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Text(String(format: "%.2f J", service.joules(shot.velocityMetersPerSecond)))
                    Text("·")
                    Text("\(service.gunName)  \(GunProfile.weightLabel(service.massGrams))")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                Text("—")
                    .font(.system(size: 88, weight: .bold, design: .rounded))
                    .foregroundStyle(.tertiary)
                Text("撃つと自動でセッションが始まります")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - 直近 10 発

    @ViewBuilder
    private var recentShots: some View {
        let shots = service.recentShots()
        if !shots.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("直近 \(shots.count) 発")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)

                ForEach(Array(shots.enumerated()), id: \.element.id) { index, shot in
                    HStack {
                        Text("\(service.currentShots.count - index)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 32, alignment: .leading)
                        Text(service.formattedSpeedWithUnit(shot.velocityMetersPerSecond))
                            .font(.body.monospacedDigit())
                        Spacer()
                        Text(String(format: "%.2f J", service.joules(shot.velocityMetersPerSecond)))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    if index < shots.count - 1 { Divider() }
                }
            }
            .padding()
            .background(.background.secondary, in: .rect(cornerRadius: 12))
        }
    }
}

// MARK: - 接続ピル

struct ConnectionPill: View {
    let state: ConnectionState
    let isReplaying: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(label)
                .font(.footnote.weight(.medium))
            if state.isBusy {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(color.opacity(0.14), in: .capsule)
        .foregroundStyle(color)
    }

    private var label: String {
        let base: String = switch state {
        case .idle: "待機中"
        case .scanning: "機器を探しています"
        case .connecting: "接続中"
        case .pairing: "準備中"
        case .ready: "接続済み"
        case .disconnected(let reason): reason.map { "切断: \($0)" } ?? "切断されました"
        }
        return isReplaying ? "\(base)（デモ再生）" : base
    }

    private var color: Color {
        switch state {
        case .ready: .green
        case .scanning, .connecting, .pairing: .orange
        case .idle: .secondary
        case .disconnected: .red
        }
    }
}

// MARK: - 統計カード

struct StatsCard: View {
    let stats: SessionStats
    let speedUnit: SpeedUnit
    let rateOfFireUnit: RateOfFireUnit
    /// 本体が ROF を報告しない場合に使うタイムスタンプ推定値。
    var fallbackRateOfFireRPS: Double?

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("セッション統計")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(stats.count) 発")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                cell("平均", speed: stats.meanMetersPerSecond)
                cell("最大", speed: stats.maxMetersPerSecond)
                cell("最小", speed: stats.minMetersPerSecond)
                cell("SD", speed: stats.sampleStandardDeviation)
                cell("ES", speed: stats.extremeSpread)
                rateOfFireCell
            }

            if let joules = stats.meanJoules {
                Divider()
                HStack {
                    Text("平均 \(String(format: "%.2f", joules)) J")
                    if let maxJ = stats.maxJoules {
                        Text("· 最大 \(String(format: "%.2f", maxJ)) J")
                    }
                    Spacer()
                    Text(GunProfile.weightLabel(stats.massGrams))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if isEstimatedRateOfFire {
                Text("* 連射速度は本体からの報告が無いため、ショット間隔から推定した値です。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }

    private func cell(_ title: String, speed: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(speed.map { speedUnit.format(metersPerSecond: $0) } ?? "—")
                .font(.title3.weight(.semibold).monospacedDigit())
        }
    }

    /// 本体が報告した ROF を優先し、無ければタイムスタンプ推定にフォールバックする。
    /// 推定値のときだけ `*` を付け、下の凡例で断りを入れる。
    private var isEstimatedRateOfFire: Bool {
        stats.meanRateOfFireRPS == nil && fallbackRateOfFireRPS != nil
    }

    private var rateOfFireCell: some View {
        let rps = stats.meanRateOfFireRPS ?? fallbackRateOfFireRPS
        return VStack(alignment: .leading, spacing: 2) {
            Text(rateOfFireUnit.symbol.uppercased() + (isEstimatedRateOfFire ? " *" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(rps.map { rateOfFireUnit.format(rps: $0) } ?? "—")
                .font(.title3.weight(.semibold).monospacedDigit())
        }
    }
}

#Preview {
    LiveView()
        .environment(ChronoService(defaults: PreviewSupport.defaults, forceReplay: true))
        .modelContainer(PreviewSupport.container)
}
