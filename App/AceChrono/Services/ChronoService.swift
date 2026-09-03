import AceChronoKit
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
    private(set) var discoveredPeripherals: [DiscoveredPeripheral] = []
    /// 本体が報告したバッテリー残量（%）。AC6000 では届かない可能性が高い（未検証コマンド）。
    private(set) var batteryPercent: Int?
    /// 本体が選択している弾。重量スケールが未確定なのでジュール計算には使わない。
    private(set) var deviceAmmo: AmmoRecord?
    /// リプレイ（デモ）モードで動いているか。
    let isReplaying: Bool

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
            defaults.set(selectedProfile?.name, forKey: Keys.selectedProfileName)
            recomputeStats()
        }
    }

    /// 統計・ジュール計算に使う BB 重量。プロファイル未選択なら 0.25 g。
    var massGrams: Double { selectedProfile?.bbWeightGrams ?? 0.25 }
    var gunName: String { selectedProfile?.name ?? String(localized: "未設定") }

    // MARK: - 内部

    private enum Keys {
        static let speedUnit = "acechrono.speedUnit"
        static let rateOfFireUnit = "acechrono.rateOfFireUnit"
        static let autoReconnect = "acechrono.autoReconnect"
        static let selectedProfileName = "acechrono.selectedProfileName"
    }

    private let device: ChronoDevice
    private let defaults: UserDefaults
    private var modelContext: ModelContext?
    private var eventTask: Task<Void, Never>?

    // MARK: - 生成

    init(defaults: UserDefaults = .standard, forceReplay: Bool? = nil) {
        self.defaults = defaults
        self.isReplaying = forceReplay ?? ReplaySupport.isEnabled

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
            decoder: AceChronoDecoder(),
            store: UserDefaultsKeyValueStore(defaults: defaults),
            configuration: .ac6000(
                autoReconnect: defaults.object(forKey: Keys.autoReconnect) as? Bool ?? true
            )
        )
    }

    /// SwiftData のコンテキストを渡してイベントの取り込みを始める。View の `.task` から呼ぶ。
    func start(modelContext: ModelContext) {
        if self.modelContext == nil { self.modelContext = modelContext }
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

    // MARK: - イベント処理

    private func handle(_ event: ChronoEvent) {
        switch event {
        case .shot(let shot):
            append(shot)
        case .connectionState(let state):
            connectionState = state
            if state == .scanning { discoveredPeripherals = [] }
        case .battery(let percent):
            batteryPercent = percent
        case .ammo(let record):
            // 本体が選んでいる弾。要求していなくても飛んでくる（`docs/PROTOCOL.md` §6.2）。
            // 重量のスケールが未確定なので、アプリの計算には使わず表示情報として持つだけ。
            if record.isCurrent { deviceAmmo = record }
        case .powerOff:
            // 本体の電源 OFF。接続状態は ChronoDevice 側が落としてくれる。
            break
        case .ack, .logCount, .deviceInfo, .raw:
            break
        }
    }

    private func append(_ shot: Shot) {
        lastShot = shot
        currentShots.append(shot)

        guard let modelContext else {
            recomputeStats()
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
        let profile = selectedProfile
        let session = Session(
            startedAt: Date(),
            gunName: gunName,
            bbWeightGrams: massGrams,
            gunPowerSource: profile?.powerSource,
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
        activeSession = nil
        currentShots = []
        lastShot = nil
        recomputeStats()
    }

    /// 進行中セッションを破棄する（誤射などをまとめて捨てる）。
    func discardSession() {
        if let session = activeSession, let modelContext {
            modelContext.delete(session)
            try? modelContext.save()
        }
        activeSession = nil
        currentShots = []
        lastShot = nil
        recomputeStats()
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
    }
}
