import MuzzlemeterKit
import SwiftData
import SwiftUI

/// 起動時の画面。UX 原則「射撃中は片手・一瞥で読めること」。
///
/// - **待機中**（まだ 1 発も撃っていない）: 画面の中央に**いま選ばれているプロファイル**を
///   大きく出す。初めて使う人がこの画面だけで「ジュールは BB 重量から計算される」ことと
///   「撃てば勝手に始まる」ことを理解できるようにするため。
/// - **計測中**: 直近弾速（超大文字）/ ジュール・プロファイル / 統計カード / 直近 10 発。
struct LiveView: View {
    @Environment(ChronoService.self) private var service
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \GunProfile.createdAt) private var profiles: [GunProfile]

    @State private var isAddingProfile = false
    @State private var isEditingVariables = false
    @State private var isShowingProfileDetail = false
    @State private var isChoosingDevice = ScreenshotSupport.opensScanSheet

    var body: some View {
        @Bindable var service = service

        NavigationStack {
            Group {
                if service.currentShots.isEmpty {
                    // 待機中は項目が少ないので、スクロールさせずに画面の中央へ置く。
                    VStack(spacing: 20) {
                        connectionPill
                        ammoMismatchBanner
                        Spacer()
                        idleState(selection: $service.selectedProfile)
                        Spacer()
                        Spacer()
                    }
                    .padding()
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            connectionPill
                            ammoMismatchBanner

                            lastVelocity(selection: $service.selectedProfile)

                            StatsCard(
                                stats: service.stats,
                                speedUnit: service.speedUnit,
                                rateOfFireUnit: service.rateOfFireUnit,
                                fallbackRateOfFireRPS: service.displayRateOfFireRPS,
                                energyLimitJoules: service.energyLimitJoules,
                                overLimitCount: service.overLimitCount
                            )

                            recentShots
                        }
                        .padding()
                    }
                }
            }
            // N 発モードのまとめ。画面に重ねて出し、遷移はしない。
            .overlay {
                if let summary = service.completedSummary {
                    SessionSummaryOverlay(
                        summary: summary,
                        onRepeat: {
                            withAnimation(.snappy) {
                                service.dismissCompletedSummary(clearsTarget: false)
                            }
                        },
                        onClose: {
                            withAnimation(.snappy) {
                                service.dismissCompletedSummary(clearsTarget: true)
                            }
                        }
                    )
                }
            }
            .animation(.snappy, value: service.completedSummary)
            .navigationTitle("Live")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("終了して保存", systemImage: "checkmark.circle") {
                            service.endSession()
                        }
                        .disabled(service.currentShots.isEmpty)
                        Button("破棄する", systemImage: "trash", role: .destructive) {
                            service.discardSession()
                        }
                        .disabled(service.currentShots.isEmpty)
                    } label: {
                        Label("セッション", systemImage: "ellipsis.circle")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            .sheet(isPresented: $isAddingProfile) {
                GunProfileEditor(profile: nil) { draft in
                    let profile = draft.makeProfile()
                    modelContext.insert(profile)
                    try? modelContext.save()
                    // 作った直後は「それを使いたい」はずなので、そのまま選択状態にする。
                    service.selectedProfile = profile
                }
            }
            // 詳細は Live のスタックに積まず**シート**で出す。計測中に画面を
            // 押しのけると、弾速の巨大数字が見えなくなる時間ができてしまう。
            .sheet(isPresented: $isShowingProfileDetail) {
                if let profile = service.selectedProfile {
                    NavigationStack {
                        GunProfileDetailView(profile: profile)
                    }
                    .environment(service)
                }
            }
            .sheet(isPresented: $isChoosingDevice) {
                DeviceScanSheet()
                    .environment(service)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isEditingVariables) {
                // 中くらいの高さ。後ろの Live 画面（弾速）が見えたままになるので、
                // 「作業を止めるモーダル」に見えない。
                SessionVariablesSheet(service: service)
                    .environment(service)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    /// 接続状態のピル。**タップで機器の一覧を開く。**
    ///
    /// 状態表示と「繋ぎ直す」操作が同じ場所にあるのが自然で、
    /// 「いま何に繋がっているのか怪しい」と思った瞬間に押せる位置はここしかない。
    private var connectionPill: some View {
        Button {
            isChoosingDevice = true
        } label: {
            ConnectionPill(
                state: service.connectionState,
                isReplaying: service.isReplaying,
                foundCount: service.discovery.count
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("機器の一覧を開きます"))
    }

    /// N 発モードの進捗「7 / 10」。目標が無いセッションでは何も出さない。
    ///
    /// 数字だけでなくバーも出すのは、射撃中に読むのが一瞥だからで、
    /// 「あと少し」を形で掴めるようにするため。
    @ViewBuilder
    private var targetProgress: some View {
        if let target = service.shotTarget, let text = service.targetProgressText {
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "target")
                        .font(.caption2)
                    Text(verbatim: text)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText())
                }
                ProgressView(value: target.progress(shotCount: service.currentShots.count))
                    .frame(width: 140)
            }
            .foregroundStyle(.secondary)
            .animation(.snappy, value: service.currentShots.count)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("目標発数の進捗"))
        }
    }

    /// 本体の弾設定とセッションの BB 重量が食い違っているときだけ出る帯。
    @ViewBuilder
    private var ammoMismatchBanner: some View {
        if let mismatch = service.ammoWeightMismatch {
            AmmoMismatchBanner(
                mismatch: mismatch,
                onAdopt: { withAnimation(.snappy) { service.adoptDeviceAmmoWeight() } },
                onDismiss: { withAnimation(.snappy) { service.dismissAmmoMismatch() } }
            )
        }
    }

    /// プロファイルピルの直下に添える条件の 1 行。プロファイルが 1 つも無いときは出さない
    /// （条件の置き場所（プロファイル）がまだ無いので、押しても意味が無い）。
    @ViewBuilder
    private func variablesLine(isCompact: Bool) -> some View {
        if !profiles.isEmpty {
            SessionVariablesLine(
                variables: service.variables,
                category: service.powerCategory,
                isCompact: isCompact
            ) {
                isEditingVariables = true
            }
        }
    }

    // MARK: - 待機中

    /// まだ 1 発も撃っていないときの画面中央。
    @ViewBuilder
    private func idleState(selection: Binding<GunProfile?>) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "scope")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)

            if profiles.isEmpty {
                // プロファイルが 1 つも無いと BB 重量が決まらず、ジュールが出せない。
                // 「何をすればいいか」を 1 アクションで示す。
                Text("プロファイルがありません")
                    .font(.title3.weight(.semibold))
                Text("使う銃の名前と BB 重量を登録すると、1 発ごとのジュールを計算できます。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("プロファイルを作成", systemImage: "plus") {
                    isAddingProfile = true
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("計測に使うプロファイル")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ProfileMenu(
                    profiles: profiles,
                    selection: selection,
                    style: .large,
                    onCreate: { isAddingProfile = true },
                    onShowDetail: { isShowingProfileDetail = true }
                )
                variablesLine(isCompact: false)
                Text("最初の 1 発でセッションが始まります")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - 直近弾速

    @ViewBuilder
    private func lastVelocity(selection: Binding<GunProfile?>) -> some View {
        VStack(spacing: 8) {
            if let shot = service.lastShot {
                // 規制上限に対する段階で色を変える。**数字そのものに色を乗せる**のは、
                // 射撃中に見るのが弾速の巨大な数字だけだから。バッジを添えるだけでは
                // 一瞥で気づけない。
                let margin = service.margin(forSpeed: shot.velocityMetersPerSecond)
                Text(service.formattedSpeed(shot.velocityMetersPerSecond))
                    .font(.system(size: 88, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .foregroundStyle(margin.tint ?? .primary)
                    .animation(.snappy, value: shot.velocityMetersPerSecond)
                HStack(spacing: 6) {
                    Text(service.speedUnit.symbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if margin.needsAttention {
                        Text(margin.label)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background((margin.tint ?? .secondary).opacity(0.16), in: .capsule)
                            .foregroundStyle(margin.tint ?? .secondary)
                    }
                }
                Text(JouleFormat.labeled(service.joules(shot.velocityMetersPerSecond)))
                    .font(.callout.weight(margin.needsAttention ? .semibold : .regular))
                    .foregroundStyle(margin.tint ?? .secondary)
            }
            // 計測中もプロファイルは見えているべき（ジュールの根拠だから）で、
            // かつその場で切り替えられるべきなので、待機中と同じ操作にする。
            ProfileMenu(
                profiles: profiles,
                selection: selection,
                style: .compact,
                onCreate: { isAddingProfile = true },
                onShowDetail: { isShowingProfileDetail = true }
            )
            variablesLine(isCompact: true)
            targetProgress
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
                    // 上限を越えた 1 発は、リストの中でも赤で見分けられるようにする。
                    // 「さっき鳴ったのは何発目だったか」を後から追えないと調整に使えない。
                    let margin = service.margin(forSpeed: shot.velocityMetersPerSecond)
                    HStack {
                        Text(verbatim: "\(service.currentShots.count - index)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 32, alignment: .leading)
                        Text(service.formattedSpeedWithUnit(shot.velocityMetersPerSecond))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(margin.tint ?? .primary)
                        if margin.isOver {
                            Image(systemName: margin.symbolName)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .accessibilityLabel(Text("超過"))
                        }
                        Spacer()
                        Text(JouleFormat.labeled(service.joules(shot.velocityMetersPerSecond)))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(margin.tint ?? .secondary)
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

// MARK: - プロファイル切り替え

/// いま選ばれているプロファイルを**文字で**見せ、そのままタップで切り替えられるピル。
///
/// 以前はツールバーの `scope` アイコン 1 個だったが、アイコンだけでは「これを押すと
/// プロファイルが変わる」と分からなかった。名前・重量・シェブロンを出して、
/// 表示（いま何で計測しているか）と操作（切り替え）を同じ場所に置く。
struct ProfileMenu: View {
    enum Style {
        /// 待機中の画面中央。名前を大きく出す。
        case large
        /// 計測中に弾速の下へ添える。
        case compact
    }

    let profiles: [GunProfile]
    @Binding var selection: GunProfile?
    var style: Style = .compact
    var onCreate: () -> Void
    /// 選択中プロファイルの詳細を開く。`nil` なら項目を出さない。
    var onShowDetail: (() -> Void)?

    var body: some View {
        Menu {
            Picker("銃プロファイル", selection: $selection) {
                ForEach(profiles) { profile in
                    Text(verbatim: "\(profile.name)  \(GunProfile.weightLabel(profile.defaultBBWeightGrams))")
                        .tag(Optional(profile))
                }
            }
            Divider()
            // 「いまこの銃はどうなっているか」（推移・仕様）は、計測中でも
            // ここから 1 手で見られるべき。設定タブまで戻らせない。
            if let onShowDetail, selection != nil {
                Button("プロファイルの詳細", systemImage: "info.circle", action: onShowDetail)
            }
            Button("新規プロファイル", systemImage: "plus", action: onCreate)
        } label: {
            // 重量はピルではなく**直下のセッション条件の行**に出す。ピルにプロファイルの
            // 既定値を出すと、その回だけ 0.30 g にしたときに 2 つの重量が食い違って見える。
            HStack(spacing: 6) {
                Text(name)
                    .font(nameFont)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, style == .large ? 18 : 14)
            .padding(.vertical, style == .large ? 12 : 8)
            .background(.background.secondary, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("銃プロファイル"))
        .accessibilityValue(Text(name))
    }

    private var name: String {
        selection?.name ?? String(localized: "未設定")
    }

    private var nameFont: Font {
        style == .large ? .title2.weight(.semibold) : .callout.weight(.medium)
    }
}

// MARK: - 接続ピル

struct ConnectionPill: View {
    let state: ConnectionState
    let isReplaying: Bool
    /// スキャンで見つかっている台数。1 台より多いときだけ出す
    /// （**取り違えが起こり得る状況かどうか**が一目で分かる）。
    var foundCount: Int = 0

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(label)
                .font(.footnote.weight(.medium))
            if foundCount > 1 {
                Text("\(foundCount) 台")
                    .font(.caption2.weight(.semibold).monospacedDigit())
            }
            if state.isBusy {
                ProgressView().controlSize(.mini)
            }
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(color.opacity(0.14), in: .capsule)
        .foregroundStyle(color)
    }

    private var label: String {
        let base: String = switch state {
        case .idle: String(localized: "待機中")
        case .scanning: String(localized: "機器を探しています")
        case .connecting: String(localized: "接続中")
        case .pairing: String(localized: "準備中")
        case .ready: String(localized: "接続済み")
        case .disconnected(let reason):
            reason.map { String(localized: "切断: \(ConnectionReasonText.localized($0))") }
                ?? String(localized: "切断されました")
        }
        return isReplaying ? String(localized: "\(base)（デモ再生）") : base
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
    /// このセッションに効いている規制上限（J）。
    var energyLimitJoules: Double = 0.98
    /// 上限を越えた発数。`SessionStats` は 1 発ごとの値を持たないので、外から渡す。
    var overLimitCount: Int = 0

    /// 「項目名をタップすると説明が出る」ことに一度でも気づいたか。
    /// 気づいたあとも案内を出し続けるのは邪魔なので、1 回で消す。
    @AppStorage("muzzlemeter.statsHintSeen") private var hintSeen = false
    @State private var isShowingGlossary = false

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("セッション統計")
                    .font(.subheadline.weight(.semibold))
                Button {
                    isShowingGlossary = true
                    hintSeen = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("統計の見かた"))
                .popover(isPresented: $isShowingGlossary) { StatGlossary() }
                Spacer()
                Text("\(stats.count) 発")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                cell(.mean, speed: stats.meanMetersPerSecond)
                cell(.max, speed: stats.maxMetersPerSecond)
                cell(.min, speed: stats.minMetersPerSecond)
                cell(.standardDeviation, speed: stats.sampleStandardDeviation)
                cell(.extremeSpread, speed: stats.extremeSpread)
                rateOfFireCell
            }

            if let joules = stats.meanJoules {
                Divider()
                HStack {
                    StatCell(
                        term: .joules,
                        title: String(localized: "平均 \(JouleFormat.labeled(joules))"),
                        value: nil,
                        onOpen: { hintSeen = true }
                    )
                    if let maxJ = stats.maxJoules {
                        Text("· 最大 \(JouleFormat.labeled(maxJ))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(GunProfile.weightLabel(stats.massGrams))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)

                // 「上限 0.98 J · 余裕 0.12 J」。基準は**最も高かった 1 発**。
                // 平均で見ると、平均は余裕なのに何発か越えている状態を見落とす。
                HStack {
                    EnergyLimitLine(
                        limitJoules: energyLimitJoules,
                        headroomJoules: headroom,
                        margin: sessionMargin
                    )
                    Spacer()
                    if overLimitCount > 0 {
                        Text("超過 \(overLimitCount) 発")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }
            }

            if isEstimatedRateOfFire {
                Text("* 連射速度は本体からの報告が無いため、ショット間隔から推定した値です。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !hintSeen {
                Text("項目名をタップすると説明が出ます。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }

    private func cell(_ term: StatTerm, speed: Double?) -> some View {
        StatCell(
            term: term,
            title: term.shortTitle,
            value: speed.map { speedUnit.format(metersPerSecond: $0) } ?? "—",
            onOpen: { hintSeen = true }
        )
    }

    /// 上限までの余裕（J）。最も高かった 1 発を基準にする。
    private var headroom: Double? {
        stats.maxJoules.map { EnergyLimit.headroomJoules(joules: $0, limitJoules: energyLimitJoules) }
    }

    /// セッション全体の段階（最も高かった 1 発で決まる）。
    private var sessionMargin: EnergyMargin {
        guard let maxJoules = stats.maxJoules else { return .safe }
        return EnergyLimit.margin(joules: maxJoules, limitJoules: energyLimitJoules)
    }

    /// 本体が報告した ROF を優先し、無ければタイムスタンプ推定にフォールバックする。
    /// 推定値のときだけ `*` を付け、下の凡例で断りを入れる。
    private var isEstimatedRateOfFire: Bool {
        stats.meanRateOfFireRPS == nil && fallbackRateOfFireRPS != nil
    }

    private var rateOfFireCell: some View {
        let rps = stats.meanRateOfFireRPS ?? fallbackRateOfFireRPS
        return StatCell(
            term: .rateOfFire,
            title: rateOfFireUnit.symbol.uppercased() + (isEstimatedRateOfFire ? " *" : ""),
            value: rps.map { rateOfFireUnit.format(rps: $0) } ?? "—",
            onOpen: { hintSeen = true }
        )
    }
}

/// 統計 1 項目。**項目名を押すと説明が出る**ことが分かるよう、見出しに点線の下線を引く。
private struct StatCell: View {
    let term: StatTerm
    let title: String
    /// `nil` なら見出しだけの 1 行（ジュールの行で使う）。
    var value: String?
    var onOpen: () -> Void

    @State private var isExplaining = false

    var body: some View {
        Button {
            isExplaining = true
            onOpen()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(value == nil ? .footnote : .caption)
                    .foregroundStyle(.secondary)
                    .underline(true, pattern: .dot)
                if let value {
                    Text(value)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
            }
            .frame(maxWidth: value == nil ? nil : .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isExplaining) { StatExplanation(term: term) }
    }
}

#Preview {
    LiveView()
        .environment(ChronoService(defaults: PreviewSupport.defaults, forceReplay: true))
        .modelContainer(PreviewSupport.container)
}
