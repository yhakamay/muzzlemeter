import MuzzlemeterKit
import Foundation
import Observation
import SwiftData

/// `ChronoDevice`（actor）と SwiftData / SwiftUI の橋渡し。
///
/// - ドメイン層は `AsyncStream<ChronoEvent>` を流すだけで UI を知らない。
///   その流れを `@MainActor` で受けて `@Observable` なプロパティに落とすのがここ。
/// - セッションは**最初の 1 発で自動的に始まる**。UX 原則「モーダルで作業を止めない」に従い、
///   撃つ前に「開始」を押させない。
@MainActor
@Observable
final class ChronoService {
    // MARK: - 表示用の状態

    private(set) var connectionState: ConnectionState = .idle
    private(set) var lastShot: Shot?
    /// 進行中セッションのショット（新しい順ではなく時刻順）。
    private(set) var currentShots: [Shot] = []
    private(set) var stats: SessionStats = .empty()
    /// スキャンで見つかっている機器（前回接続の印つき）。接続ピルのシートに出す。
    private(set) var discovery = DiscoveryList()
    /// 本体が報告したバッテリー残量（%）。AC6000 では届かない可能性が高い（未検証コマンド）。
    private(set) var batteryPercent: Int?
    /// 本体が選択している弾。重量スケールが未確定なのでジュール計算には使わない。
    private(set) var deviceAmmo: AmmoRecord?
    /// リプレイ（デモ）モードで動いているか。
    let isReplaying: Bool
    /// 音・振動・読み上げ。設定画面はこの中のトグルを直接束縛する。
    let feedback: FeedbackService
    /// ロック画面 / Dynamic Island のライブアクティビティ（Round E）。
    private let liveActivity: LiveActivityService
    /// セッション終了時にホーム画面ウィジェット用のまとめを書く（Round E）。
    private let homeWidgetWriter: HomeWidgetSnapshotWriter
    /// Apple Watch アプリへの中継（Round E）。BLE の中心は iPhone のまま。
    private let watchConnectivity: WatchConnectivityService

    /// 進行中のセッション。1 発も撃っていなければ nil。
    private(set) var activeSession: Session?

    // MARK: - 設定（UserDefaults 永続）

    var speedUnit: SpeedUnit {
        didSet { defaults.set(speedUnit.rawValue, forKey: Keys.speedUnit) }
    }

    var rateOfFireUnit: RateOfFireUnit {
        didSet { defaults.set(rateOfFireUnit.rawValue, forKey: Keys.rateOfFireUnit) }
    }

    var autoReconnect: Bool {
        didSet {
            defaults.set(autoReconnect, forKey: Keys.autoReconnect)
            let device = self.device
            let value = autoReconnect
            Task { await device.setAutoReconnect(value) }
        }
    }

    /// 選択中の銃プロファイル。ジュール計算と新規セッションのスナップショットに使う。
    var selectedProfile: GunProfile? {
        didSet {
            // Compare identities explicitly. `!=` on a SwiftData `@Model` reference
            // relies on a synthesized Equatable conformance that some toolchains do
            // not provide here, and the check we actually want is "a different
            // profile object", not value equality of its fields.
            guard selectedProfile !== oldValue else { return }
            defaults.set(selectedProfile?.name, forKey: Keys.selectedProfileName)
            // 銃を替えたら、次のセッションの条件はその銃の既定値から始める。
            // 前の銃の 0.20 g が黙って引き継がれると、ジュールが静かに間違う。
            pendingVariables = selectedProfile?.defaultVariables ?? SessionVariables()
            recomputeStats()
        }
    }

    /// **次のセッションが始まるときの条件**。待機中に編集できるのはこれ。
    ///
    /// セッションはまだ存在しない（1 発目で作られる）ので、条件を置いておく場所が要る。
    /// プロファイルの既定値からコピーして持ち、1 発目でセッションへ焼き込む。
    private(set) var pendingVariables = SessionVariables()

    /// いま効いている計測条件。計測中はセッションの値、待機中は `pendingVariables`。
    ///
    /// 書き込むと、計測中ならセッション全体（統計・ジュール・CSV）が計算し直される。
    var variables: SessionVariables {
        get { activeSession?.variables ?? pendingVariables }
        set {
            let normalized = newValue.normalized
            if let session = activeSession {
                session.variables = normalized
                try? modelContext?.save()
            } else {
                pendingVariables = normalized
            }
            recomputeStats()
        }
    }

    /// いま効いているパワーソース区分。ガス種別を訊くかどうかの判定に使う。
    var powerCategory: PowerCategory {
        activeSession?.gunPowerCategory ?? selectedProfile?.powerCategory ?? .electric
    }

    /// いま効いている規制上限（J）。
    var energyLimitJoules: Double {
        activeSession?.energyLimitJoules ?? selectedProfile?.energyLimitJoules ?? 0.98
    }

    /// 統計・ジュール計算に使う BB 重量。
    var massGrams: Double { variables.bbWeightGrams }

    // MARK: - N 発モード

    /// いま効いている目標発数。成立していなければ `nil`（手動で締める）。
    var shotTarget: ShotTarget? { variables.target }

    /// 「7 / 10」の進捗。目標が無ければ `nil`。
    var targetProgressText: String? {
        guard let target = shotTarget else { return nil }
        return "\(currentShots.count) / \(target.count)"
    }

    /// 目標発数に届いて自動的に締めたセッションのまとめ。表示したら `nil` に戻す。
    ///
    /// `Identifiable` にしてあるのは、同じ内容のまとめが 2 回続いても
    /// SwiftUI が別物として出せるようにするため（同じ条件で 2 回撃つのは普通にある）。
    struct CompletedSummary: Identifiable, Equatable {
        let id = UUID()
        let stats: SessionStats
        let overLimitCount: Int
        let energyLimitJoules: Double
        let targetShotCount: Int
        let speedUnit: SpeedUnit
    }

    private(set) var completedSummary: CompletedSummary?

    /// まとめを閉じる。`clearsTarget` が真なら目標発数も解除する（「閉じる」）。
    func dismissCompletedSummary(clearsTarget: Bool) {
        completedSummary = nil
        guard clearsTarget else { return }
        var updated = variables
        updated.targetShotCount = nil
        variables = updated
    }

    /// 目標に届いていればセッションを締めて、まとめを作る。
    ///
    /// **締めるのは保存が終わってから。** 途中で締めると最後の 1 発が
    /// セッションに入らないまま「N 発撃った」ことになる。
    private func finishIfTargetReached() {
        guard let target = shotTarget, target.isReached(shotCount: currentShots.count) else {
            return
        }
        let summary = CompletedSummary(
            stats: stats,
            overLimitCount: overLimitCount,
            energyLimitJoules: energyLimitJoules,
            targetShotCount: target.count,
            speedUnit: speedUnit
        )
        endSession()
        completedSummary = summary
        feedback.reportSessionCompleted()
    }

    // MARK: - 本体の弾設定との不一致

    /// 本体が報告した弾の重量と、いま効いている BB 重量の食い違い。
    struct AmmoWeightMismatch: Equatable {
        /// 本体が選んでいる弾の重量（g）。
        let deviceGrams: Double
        /// セッション（待機中なら次のセッション）の BB 重量（g）。
        let sessionGrams: Double
    }

    /// 「同じ」と見なす差。表示は小数 2 桁なので、それより細かい差で警告しても意味が無い。
    static let ammoWeightTolerance = 0.005

    /// 「無視」された食い違い。**同じ組み合わせの間だけ**黙る。
    private var dismissedAmmoMismatch: AmmoWeightMismatch?

    /// 出すべき警告。無ければ `nil`。
    ///
    /// **本体には何も書き込まない。** 本体の設定を勝手に変えると、アプリを閉じた後の
    /// 本体単体の表示まで変わってしまう。食い違いを知らせて、直すかどうかは人が決める。
    var ammoWeightMismatch: AmmoWeightMismatch? {
        guard let deviceGrams = deviceAmmo?.weightGrams else { return nil }
        let mismatch = AmmoWeightMismatch(deviceGrams: deviceGrams, sessionGrams: massGrams)
        guard abs(mismatch.deviceGrams - mismatch.sessionGrams) > Self.ammoWeightTolerance else {
            return nil
        }
        // 無視した後で本体かセッションのどちらかが変われば、また出す。
        return mismatch == dismissedAmmoMismatch ? nil : mismatch
    }

    /// セッションの BB 重量を本体に合わせる。
    func adoptDeviceAmmoWeight() {
        guard let mismatch = ammoWeightMismatch else { return }
        var updated = variables
        updated.bbWeightGrams = mismatch.deviceGrams
        variables = updated
        dismissedAmmoMismatch = nil
    }

    /// この食い違いについては黙る（次に値が変わるまで）。
    func dismissAmmoMismatch() {
        dismissedAmmoMismatch = ammoWeightMismatch
    }

    // MARK: - 本体内ログの取り込み
    //
    // 本体内ログは **volatile**（`docs/PROTOCOL.md` §6.5 / §6.6。電源を切ると 0 件に戻る）。
    // そのため「件数が変わったら促す」だけでは足りない: 6 件取り込んだ後に本体の電源が
    // 入り直り、新たに 3 発撃たれると件数はまた「3」になる。件数の比較だけで済ませると、
    // 「6 と 3 は違う」→促す、まではよいが、**取り込みは常に index 1 から** なので
    // 前回取り込んだ 6 件のうち被る分は無い（volatile なので index 1..3 は新しい記録）。
    // 一方、電源が入ったままさらに 3 発撃ち足された場合（件数が 6→9）は、index 1..6 を
    // 二重に読んでしまう。これを避けるため、**件数**ではなく**どこまで読んだ index か**
    // （`importedThroughIndex`）を機器ごとに覚え、差分（`importedThroughIndex+1...count`）
    // だけを読む。件数が前回より**減っていたら**電源サイクルとみなして 0 に戻す。

    /// 本体が報告したログ件数（`0x62`）。未取得なら nil。
    private(set) var deviceLogCount: Int?
    /// 取り込みの進行状態。帯の見た目はこれだけで決まる。
    private(set) var deviceLogImport: DeviceLogImportState = .idle
    /// 「あとで」を押された件数。**この起動の間だけ**黙る（次の起動ではまた促す）。
    private var dismissedDeviceLogCount: Int?
    /// いま繋がっている機器。取り込み済みの印を機器ごとに付けるために要る。
    private var connectedPeripheralID: UUID?

    /// 機器ごとの「どこまで（何番目の index まで）取り込んだか」の印。
    private struct DeviceLogProgressRecord: Codable {
        var importedThroughIndex: Int
        var updatedAt: Date
    }

    private static func deviceLogProgressKey(for peripheral: UUID) -> String {
        "muzzlemeter.deviceLogProgress.\(peripheral.uuidString)"
    }

    private func loadDeviceLogProgress(for peripheral: UUID) -> DeviceLogProgressRecord? {
        guard let data = defaults.data(forKey: Self.deviceLogProgressKey(for: peripheral)) else {
            return nil
        }
        return try? JSONDecoder().decode(DeviceLogProgressRecord.self, from: data)
    }

    private func saveDeviceLogProgress(importedThroughIndex: Int, for peripheral: UUID) {
        let record = DeviceLogProgressRecord(importedThroughIndex: importedThroughIndex, updatedAt: Date())
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.deviceLogProgressKey(for: peripheral))
    }

    /// いま繋がっている機器で、どこまで取り込み済みか（0 = まだ何も取り込んでいない）。
    private var importedThroughIndex: Int {
        guard let id = connectedPeripheralID else { return 0 }
        return loadDeviceLogProgress(for: id)?.importedThroughIndex ?? 0
    }

    /// 「本体に未取込のログが N 件あります」と出すべき件数（＝差分の件数）。無ければ nil。
    ///
    /// **繋がっているときにしか出さない。** 押しても読み出しは始まらないのに
    /// 「取り込む」を出すと、押した人には「試したのに失敗した」としか見えない。
    var pendingDeviceLogCount: Int? {
        guard connectionState.isReady else { return nil }
        guard deviceLogImport == .idle else { return nil }
        guard let count = deviceLogCount, count > importedThroughIndex else { return nil }
        guard count != dismissedDeviceLogCount else { return nil }
        return count - importedThroughIndex
    }

    /// 取り込みを始める。**計測は止めない**（撃てば普通にショットが入る）。
    ///
    /// 読むのは `importedThroughIndex+1...count` だけ（差分）。ログは volatile なので、
    /// 同じ電源サイクルの間に既に読んだところを読み直す必要が無い。
    func importDeviceLog() {
        guard let pending = pendingDeviceLogCount,
              let count = deviceLogCount,
              let peripheral = connectedPeripheralID
        else { return }
        let startIndex = importedThroughIndex + 1
        deviceLogImport = .importing(done: 0, total: pending)
        let device = self.device
        let options = DeviceLogReadOptions(startIndex: startIndex)
        // ここだけ self を強く掴む(読み出しが終わるまでの数秒)。弱参照にすると
        // 入れ子のクロージャで「捕捉した var self」を再捕捉することになり、
        // 進捗の受け渡しがかえって読みにくくなる。ChronoService はアプリと同じ寿命。
        Task {
            let result = await device.readDeviceLog(options: options) { progress in
                Task { @MainActor in self.updateDeviceLogProgress(progress) }
            }
            self.finishDeviceLogImport(result, peripheral: peripheral, previousCount: count)
        }
    }

    /// 進捗の反映。**取り込みを止めた後の遅れて来た進捗は捨てる。**
    private func updateDeviceLogProgress(_ progress: DeviceLogProgress) {
        guard case .importing = deviceLogImport else { return }
        deviceLogImport = .importing(done: progress.done, total: progress.total)
    }

    /// 「あとで」。件数が変わるまで黙る。
    func dismissDeviceLogBanner() {
        dismissedDeviceLogCount = deviceLogCount
    }

    /// 結果の帯を閉じる。
    func dismissDeviceLogResult() {
        deviceLogImport = .idle
    }

    private func finishDeviceLogImport(
        _ result: DeviceLogReadResult,
        peripheral: UUID,
        previousCount: Int
    ) {
        let outcome: DeviceLogImportSummary.Outcome
        switch result.outcome {
        case .completed: outcome = .completed
        case .unsupportedFormat: outcome = .unsupportedFormat
        case .timedOut, .unavailable: outcome = .noResponse
        }

        var savedShotCount = 0
        if let modelContext,
           let session = DeviceLogSessionBuilder.insertSession(
               shots: result.shots,
               variables: variables,
               profile: selectedProfile,
               gunName: gunName,
               isPartial: outcome != .completed,
               into: modelContext
           ) {
            savedShotCount = session.shots.count
            try? modelContext.save()
        }

        // 読めなかったときだけ生データを残す。**これが実物の 0x63 を手に入れる唯一の経路。**
        let fileName = result.isComplete ? nil : DeviceLogArchive.write(records: result.records)

        // 印は「実際に読めた末尾の index」まで進める。部分的にしか読めなくても、
        // そこまでは確実に取り込めているので次回はその続きから読む。
        if let lastIndex = result.lastReadIndex {
            saveDeviceLogProgress(importedThroughIndex: lastIndex, for: peripheral)
        }
        dismissedDeviceLogCount = previousCount
        deviceLogImport = .finished(
            DeviceLogImportSummary(
                savedShotCount: savedShotCount,
                outcome: outcome,
                debugFileName: fileName
            )
        )
    }

    /// 接続できたら件数だけ訊く（best-effort）。
    ///
    /// 応答が無くても何も起きない。ログの読み出しは**おまけ**で、計測を妨げてはいけない。
    private func refreshDeviceLog() {
        let device = self.device
        Task { [weak self] in
            let peripheral = await device.connectedPeripheral
            let count = await device.readLogCount()
            self?.applyDeviceLogCount(count, peripheral: peripheral)
        }
    }

    private func applyDeviceLogCount(_ count: Int?, peripheral: UUID?) {
        connectedPeripheralID = peripheral
        if let count {
            deviceLogCount = count
            detectPowerCycleIfNeeded(newCount: count, peripheral: peripheral)
        }
        // 目視確認用（`--demo-device-log-auto`）。製品では常に false。
        if ScreenshotSupport.startsDeviceLogImport { importDeviceLog() }
    }

    /// 件数が前回の取り込み済み index より**減っていたら**、本体の電源が入り直った
    /// （volatile なログが 0 件に戻った）とみなして印を 0 に戻す。
    private func detectPowerCycleIfNeeded(newCount: Int, peripheral: UUID?) {
        guard let peripheral else { return }
        guard let record = loadDeviceLogProgress(for: peripheral), newCount < record.importedThroughIndex
        else { return }
        saveDeviceLogProgress(importedThroughIndex: 0, for: peripheral)
    }

    // MARK: - 規制上限

    /// 1 発を規制上限と比べた段階。色分け・音・振動はすべてこれで決まる。
    func margin(forSpeed metersPerSecond: Double) -> EnergyMargin {
        EnergyLimit.margin(
            massGrams: massGrams,
            velocityMetersPerSecond: metersPerSecond,
            limitJoules: energyLimitJoules
        )
    }

    /// 直近 1 発の段階。まだ 1 発も撃っていなければ `.safe`（＝平常の色）。
    var lastShotMargin: EnergyMargin {
        lastShot.map { margin(forSpeed: $0.velocityMetersPerSecond) } ?? .safe
    }

    /// セッション中で最も高かった 1 発の段階。カードの見出しに出す。
    var sessionMargin: EnergyMargin {
        guard let maxJoules = stats.maxJoules else { return .safe }
        return EnergyLimit.margin(joules: maxJoules, limitJoules: energyLimitJoules)
    }

    /// 上限までの余裕（J）。**最も高かった 1 発**を基準にする。
    /// 平均で見ると「平均は余裕があるのに何発か越えている」状態を見落とす。
    var headroomJoules: Double? {
        stats.maxJoules.map { EnergyLimit.headroomJoules(joules: $0, limitJoules: energyLimitJoules) }
    }

    /// このセッションで上限を越えた発数。
    var overLimitCount: Int {
        EnergyLimit.overLimitCount(
            shots: currentShots,
            massGrams: massGrams,
            limitJoules: energyLimitJoules
        )
    }

    var gunName: String { selectedProfile?.name ?? String(localized: "未設定") }

    /// いまの条件をプロファイルの既定値として書き戻す。
    func saveVariablesAsProfileDefaults() {
        guard let profile = selectedProfile else { return }
        let current = variables
        profile.defaultBBWeightGrams = current.bbWeightGrams
        profile.defaultGasType = current.gasType
        profile.defaultHopSetting = current.hopSetting
        try? modelContext?.save()
    }

    /// 条件をプロファイルの既定値へ戻す。
    func resetVariablesToProfileDefaults() {
        variables = selectedProfile?.defaultVariables ?? SessionVariables()
    }

    /// プロファイルの既定値と一致しているか（「既定値に戻す」を出すかの判定）。
    var variablesMatchProfileDefaults: Bool {
        variables.normalized == (selectedProfile?.defaultVariables ?? SessionVariables()).normalized
    }

    // MARK: - 過去のセッションを直す（Round D 続き）
    //
    // `variables` は「進行中 or 待機中」専用で、Live 画面が見ている 1 か所だけを指す。
    // セッション詳細からは**任意の**（進行中とは限らない）セッションを直せる必要があるので、
    // そちらは呼び出し側（`SessionConditionsEditor` / `SessionDetailView`）が `Session` を
    // 直接書き換え、保存だけをここに任せる。対象がたまたま進行中のセッションと同じ実体
    // だったときは、Live 画面が見ているキャッシュ（`stats`）も合わせて計算し直す。
    // そうしないと、詳細画面で BB 重量を直しても Live 画面の数字が次の 1 発まで
    // 古いままになってしまう。
    //
    // 参照の比較には `===` を使う（`selectedProfile` の didSet と同じ理由。値の中身が
    // 同じでも別の実体なら別として扱いたいので、synthesized Equatable には頼らない）。
    func saveEditedSession(_ session: Session) {
        try? modelContext?.save()
        if session === activeSession {
            recomputeStats()
        }
    }

    // MARK: - 内部

    private enum Keys {
        static let speedUnit = "muzzlemeter.speedUnit"
        static let rateOfFireUnit = "muzzlemeter.rateOfFireUnit"
        static let autoReconnect = "muzzlemeter.autoReconnect"
        static let selectedProfileName = "muzzlemeter.selectedProfileName"
    }

    private let device: ChronoDevice
    private let defaults: UserDefaults
    private var modelContext: ModelContext?
    private var eventTask: Task<Void, Never>?

    // MARK: - 生成

    init(
        defaults: UserDefaults = .standard,
        forceReplay: Bool? = nil,
        feedback: FeedbackService? = nil,
        liveActivity: LiveActivityService? = nil,
        homeWidgetWriter: HomeWidgetSnapshotWriter? = nil,
        watchConnectivity: WatchConnectivityService? = nil
    ) {
        self.defaults = defaults
        self.isReplaying = forceReplay ?? ReplaySupport.isEnabled
        self.feedback = feedback ?? FeedbackService(defaults: defaults)
        self.liveActivity = liveActivity ?? LiveActivityService()
        self.homeWidgetWriter = homeWidgetWriter ?? HomeWidgetSnapshotWriter()
        self.watchConnectivity = watchConnectivity ?? WatchConnectivityService()

        self.speedUnit = defaults.string(forKey: Keys.speedUnit)
            .flatMap(SpeedUnit.init(rawValue:)) ?? .metersPerSecond
        self.rateOfFireUnit = defaults.string(forKey: Keys.rateOfFireUnit)
            .flatMap(RateOfFireUnit.init(rawValue:)) ?? .rps
        self.autoReconnect = defaults.object(forKey: Keys.autoReconnect) as? Bool ?? true

        // 実機では CoreBluetooth、シミュレータ / `--replay` では記録済みパケットの再生。
        // **デコーダと設定は両方で同じもの**を使う。再生でも鍵ハンドシェイクまで
        // 実機と同じ経路を通るので、UI から見て挙動が変わらない。
        let transport: any ChronoTransport = self.isReplaying
            ? ReplaySupport.makeTransport()
            : CoreBluetoothTransport()
        self.device = ChronoDevice(
            transport: transport,
            decoder: MuzzlemeterDecoder(),
            store: UserDefaultsKeyValueStore(defaults: defaults),
            configuration: .ac6000(
                autoReconnect: defaults.object(forKey: Keys.autoReconnect) as? Bool ?? true
            )
        )
    }

    /// SwiftData のコンテキストを渡してイベントの取り込みを始める。View の `.task` から呼ぶ。
    func start(modelContext: ModelContext) {
        if self.modelContext == nil { self.modelContext = modelContext }
        // プロファイルを読む前に走らせる。旧「パワーソース」を区分とガス種別へ割る。
        StoreMigration.run(in: modelContext)
        restoreSelectedProfileIfNeeded()
        closeSessionsLeftOpen(in: modelContext)
        guard eventTask == nil else { return }

        let stream = device.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
        let device = self.device
        Task { await device.start() }
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        let device = self.device
        Task { await device.stop() }
    }

    /// 覚えている機器を忘れる（設定画面から）。
    func forgetDevice() {
        let device = self.device
        Task {
            await device.forgetDevice()
            await device.stop()
            await device.start()
        }
    }

    func reconnect() {
        let device = self.device
        Task { await device.start() }
    }

    /// 一覧から選んだ機器に繋ぐ。
    ///
    /// 自動接続（覚えている機器 / 最初に見つかった機器）はそのまま生きていて、
    /// これは**それを上書きする明示的な操作**。複数台が同時に電源が入っている場面で、
    /// 意図しない 1 台に繋がったときに選び直せるようにするために要る。
    func connect(to peripheral: DiscoveredPeripheral) {
        let device = self.device
        let id = peripheral.id
        Task { await device.connect(to: id) }
    }

    /// スキャンをやり直す（一覧に出てこない機器を探し直すとき）。
    func rescan() {
        let device = self.device
        Task {
            await device.stop()
            await device.start()
        }
    }

    // MARK: - イベント処理

    private func handle(_ event: ChronoEvent) {
        switch event {
        case .shot(let shot):
            append(shot)
        case .connectionState(let state):
            let wasReady = connectionState.isReady
            connectionState = state
            // 繋がった直後に 1 回だけ訊く。切れたら件数は忘れる（別の機器かもしれない）。
            if state.isReady, !wasReady {
                refreshDeviceLog()
            } else if !state.isReady {
                deviceLogCount = nil
            }
        case .battery(let percent):
            batteryPercent = percent
        case .ammo(let record):
            // 本体が選んでいる弾。要求していなくても飛んでくる（`docs/PROTOCOL.md` §6.2）。
            // 重量のスケールが未確定なので、アプリの計算には**使わない**。
            // 使うのは「セッションの BB 重量と食い違っていないか」の確認だけ。
            //
            // `0x5A`（現在選択中）は常に採る。`0x47`（プリセット）は、本体からの
            // 自発通知（marker 0x40）だけを「いま選ばれている弾が変わった」と読む。
            // 読み出し応答（0x41）は 5 スロットぶん順に届くので、採ると最後の
            // スロットが「現在の弾」に化ける。
            if record.isCurrent || record.marker == AmmoRecord.spontaneousMarker {
                deviceAmmo = record
            }
        case .powerOff:
            // 本体の電源 OFF。接続状態は ChronoDevice 側が落としてくれる。
            break
        case .discovered(let list):
            // 一覧は `ChronoDevice` が持つものをそのまま映す（並べ替えの規則も含めて
            // キット側に 1 つだけ置く）。変化したときだけ届くので、ここでは代入だけ。
            discovery = list

        case .logCount(let count):
            // 要求していなくても届くことがある。届いた値をそのまま採る。
            // ただし**切れた後に遅れて届いたものは採らない**。直前に nil へ戻した
            // 件数がここで蘇ると、切断中なのに「取り込む」が出てしまう。
            guard connectionState.isReady else { break }
            deviceLogCount = count
            detectPowerCycleIfNeeded(newCount: count, peripheral: connectedPeripheralID)

        case .logRecordRaw, .logRecord, .logRecordEmpty:
            // 取り込みの本体は `ChronoDevice.readDeviceLog` が要求と対にして受け取る。
            // ここで拾うと**進行中のセッションに過去のログが混ざる**ので、何もしない。
            break

        case .ack, .nak, .deviceInfo, .raw:
            break
        }
    }

    private func append(_ shot: Shot) {
        lastShot = shot
        currentShots.append(shot)

        guard let modelContext else {
            recomputeStats()
            // 保存先が無くても（Preview など）表示と通知は同じように動かす。
            report(shot)
            return
        }
        let isNewSession = activeSession == nil
        let session = activeSession ?? beginSession(in: modelContext)
        let record = ShotRecord(shot: shot, session: session)
        modelContext.insert(record)
        session.shots.append(record)
        try? modelContext.save()
        // 気象の取得は**保存の後**に始める。保存前の `persistentModelID` は一時的な値で、
        // 後から引き直しても実体に当たらない（SwiftData がアサートで落ちる）。
        if isNewSession { captureEnvironment(for: session) }
        recomputeStats()
        // 上限の判定はセッションが決まってから（セッションが持つ上限を使う）。
        report(shot)
        // ライブアクティビティ・Watch への反映も統計・上限の判定が終わってから。
        syncLiveState(isNewSession: isNewSession)
        // N 発モードの締めは**保存の後**。途中で締めると最後の 1 発が入らない。
        finishIfTargetReached()
    }

    /// ライブアクティビティと Apple Watch へ、いまの計測状態を伝える。
    ///
    /// **セッション開始時（1 発目）は両方へ必ず反映する**（Live Activity を起動し、
    /// Watch へも状態全体を同期する）。それ以外の発は間引きに任せる（間引き自体は
    /// `LiveActivityService` / `WatchConnectivityService` の中）。
    private func syncLiveState(isNewSession: Bool) {
        guard let session = activeSession else { return }
        let content = LiveActivityContent.derive(
            shots: currentShots,
            massGrams: massGrams,
            speedUnit: speedUnit,
            energyLimitJoules: energyLimitJoules,
            target: shotTarget,
            gunName: gunName
        )
        let watchState = WatchLiveState.derive(
            shots: currentShots,
            massGrams: massGrams,
            speedUnit: speedUnit,
            energyLimitJoules: energyLimitJoules,
            target: shotTarget,
            gunName: gunName,
            isSessionActive: true
        )
        if isNewSession {
            liveActivity.start(content: content, startedAt: session.startedAt)
            watchConnectivity.syncState(watchState)
        } else {
            liveActivity.report(content: content)
        }
        watchConnectivity.reportShot(state: watchState)
    }

    /// 1 発ぶんの音・振動・読み上げを `FeedbackService` へ渡す。
    ///
    /// 読み上げの文言は**表示と同じ整形**を通す。画面に 92.5 と出ているのに
    /// 「92.53」と読まれると、どちらが本当なのか分からなくなる。
    private func report(_ shot: Shot) {
        feedback.report(
            margin: margin(forSpeed: shot.velocityMetersPerSecond),
            speedText: formattedSpeed(shot.velocityMetersPerSecond),
            joulesText: JouleFormat.value(joules(shot.velocityMetersPerSecond))
        )
    }

    /// 前回の起動で「終了して保存」を押さずに終わったセッションを閉じる。
    ///
    /// セッションは 1 発目で自動的に始まるが、終わりを明示するのはユーザーの操作だけだった。
    /// そのためアプリを落とすたびに `endedAt == nil` のセッションが残り、履歴の**全行が
    /// 「進行中」**になって、いま計測しているのがどれか分からなくなる。
    /// 起動時（まだ 1 発も受け取っていない時点）に、最後のショットの時刻で閉じてしまう。
    private func closeSessionsLeftOpen(in modelContext: ModelContext) {
        let descriptor = FetchDescriptor<Session>(predicate: #Predicate { $0.endedAt == nil })
        guard let open = try? modelContext.fetch(descriptor), !open.isEmpty else { return }
        for session in open {
            session.endedAt = session.orderedShots.last?.timestamp ?? session.startedAt
        }
        try? modelContext.save()
    }

    /// 最初の 1 発でセッションを自動開始する。
    private func beginSession(in modelContext: ModelContext) -> Session {
        // 銃の仕様はプロファイルへの参照ではなく**値でコピー**する。
        // 後からプロファイルを直しても、過去の計測が何で撃たれたかは変わらないため。
        // セッション変数は「次に始まる条件」（待機中に触れる値）をそのまま焼き込む。
        let profile = selectedProfile
        let session = Session(
            startedAt: Date(),
            gunName: gunName,
            variables: pendingVariables,
            gunPowerCategory: profile?.powerCategory,
            energyLimitJoules: profile?.energyLimitJoules ?? 0.98,
            gunManufacturer: profile?.manufacturer ?? "",
            gunModel: profile?.model ?? "",
            gunInnerBarrelLengthMm: profile?.innerBarrelLengthMm
        )
        modelContext.insert(session)
        activeSession = session
        return session
    }

    /// 計測場所の気象を記録する。
    ///
    /// **ショットの取り込みを絶対に待たせない。** 切り離したタスクで取りに行き、
    /// 戻ってきたらメインアクタでセッションへ書き戻す。失敗しても何も起きない
    /// （自動値が nil のままになるだけ）。
    private func captureEnvironment(for session: Session) {
        let id = session.persistentModelID
        Task.detached(priority: .utility) { [weak self] in
            guard let snapshot = await SessionEnvironmentService.currentConditions() else { return }
            await self?.apply(snapshot, toSessionWith: id)
        }
    }

    /// セッションは値として渡せない（`@Model` は Sendable ではない）ので、
    /// 永続 ID で引き直してから書き込む。取得中に消されていれば何もしない。
    private func apply(_ snapshot: EnvironmentSnapshot, toSessionWith id: PersistentIdentifier) {
        guard let modelContext,
              let session = modelContext.model(for: id) as? Session,
              !session.isDeleted
        else { return }
        session.autoTemperatureC = snapshot.temperatureC
        session.autoHumidity = snapshot.humidity
        session.autoPressureHPa = snapshot.pressureHPa
        session.autoConditionSymbol = snapshot.conditionSymbol
        session.autoConditionText = snapshot.conditionText
        session.placeName = snapshot.placeName
        session.latitude = snapshot.latitude
        session.longitude = snapshot.longitude
        session.weatherFetchedAt = snapshot.fetchedAt
        try? modelContext.save()
    }

    /// 進行中のセッションを確定して閉じる。
    func endSession() {
        guard let session = activeSession else { return }
        session.endedAt = Date()
        try? modelContext?.save()
        // ライブアクティビティ・Watch は**終了前の状態**（＝最後のショットまで反映した
        // 状態）で閉じる。session.endedAt を書いた後だが、統計は currentShots から
        // 計算するのでどちらでも同じ値になる。
        endLiveState()
        // 確定したセッションだけホーム画面ウィジェットへ渡す（破棄したものは出さない）。
        homeWidgetWriter.write(session: session, speedUnit: speedUnit)
        // 続けて撃つときは同じ条件のはず。締めた条件を次のセッションへ引き継ぐ
        // （プロファイルの既定値へ戻したいときは「既定値に戻す」で戻せる）。
        pendingVariables = session.variables
        activeSession = nil
        currentShots = []
        lastShot = nil
        recomputeStats()
    }

    /// 進行中セッションを破棄する（誤射などをまとめて捨てる）。
    func discardSession() {
        if let session = activeSession, let modelContext {
            pendingVariables = session.variables
            modelContext.delete(session)
            try? modelContext.save()
        }
        // 破棄でもライブアクティビティ・Watch は必ず閉じる（残ったままにしない）。
        // ホーム画面ウィジェットには**書かない**（捨てた回を「最新の記録」として出さない）。
        endLiveState()
        activeSession = nil
        currentShots = []
        lastShot = nil
        recomputeStats()
    }

    /// ライブアクティビティを終了し、Watch へ「セッション終了」を同期する。
    /// 終了・破棄の両方から呼ぶ共通処理。
    private func endLiveState() {
        let content = LiveActivityContent.derive(
            shots: currentShots,
            massGrams: massGrams,
            speedUnit: speedUnit,
            energyLimitJoules: energyLimitJoules,
            target: shotTarget,
            gunName: gunName
        )
        liveActivity.end(content: content)
        let watchState = WatchLiveState.derive(
            shots: currentShots,
            massGrams: massGrams,
            speedUnit: speedUnit,
            energyLimitJoules: energyLimitJoules,
            target: shotTarget,
            gunName: gunName,
            isSessionActive: false
        )
        watchConnectivity.syncState(watchState)
    }

    private func recomputeStats() {
        stats = SessionStats.compute(shots: currentShots, massGrams: massGrams)
    }

    // MARK: - 表示ヘルパ

    /// 直近 N 発を新しい順に返す。
    func recentShots(limit: Int = 10) -> [Shot] {
        Array(currentShots.suffix(limit).reversed())
    }

    /// 表示する連射速度（rps）。本体の報告値を優先し、無ければタイムスタンプから推定する。
    var displayRateOfFireRPS: Double? {
        if let reported = lastShot?.rateOfFireRPS { return reported }
        return RateOfFire.estimateRPS(shots: currentShots)
    }

    func formattedSpeed(_ metersPerSecond: Double) -> String {
        speedUnit.format(metersPerSecond: metersPerSecond)
    }

    func formattedSpeedWithUnit(_ metersPerSecond: Double) -> String {
        speedUnit.formatted(metersPerSecond: metersPerSecond)
    }

    func joules(_ metersPerSecond: Double) -> Double {
        Energy.joules(massGrams: massGrams, velocityMetersPerSecond: metersPerSecond)
    }

    // MARK: - プロファイル

    private func restoreSelectedProfileIfNeeded() {
        guard selectedProfile == nil, let modelContext else { return }
        let profiles = (try? modelContext.fetch(FetchDescriptor<GunProfile>())) ?? []
        if profiles.isEmpty {
            // 初回起動: 既定プロファイルを 1 つ作る。設定を強要しない。
            let profile = GunProfile(name: String(localized: "マイガン"), bbWeightGrams: 0.25)
            modelContext.insert(profile)
            try? modelContext.save()
            selectedProfile = profile
            return
        }
        let remembered = defaults.string(forKey: Keys.selectedProfileName)
        selectedProfile = profiles.first { $0.name == remembered }
            ?? profiles.sorted { $0.createdAt < $1.createdAt }.first
        applyScreenshotOverrides()
    }

    /// 目視確認用の起動引数を選択中プロファイルへ反映する（Debug のシミュレータのみ）。
    private func applyScreenshotOverrides() {
        guard let profile = selectedProfile else { return }
        var changed = false
        if let limit = ScreenshotSupport.energyLimitOverride, limit > 0 {
            profile.energyLimitJoules = limit
            changed = true
        }
        if let target = ScreenshotSupport.targetShotCountOverride {
            profile.targetShotCount = ShotTarget(target)?.count
            pendingVariables = profile.defaultVariables
            changed = true
        }
        guard changed else { return }
        try? modelContext?.save()
    }
}
