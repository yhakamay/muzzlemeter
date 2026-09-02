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
    var gunName: String { selectedProfile?.name ?? "未設定" }

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
        self.isReplaying = forceReplay ?? DemoReplay.isEnabled

        self.speedUnit = defaults.string(forKey: Keys.speedUnit)
            .flatMap(SpeedUnit.init(rawValue:)) ?? .metersPerSecond
        self.rateOfFireUnit = defaults.string(forKey: Keys.rateOfFireUnit)
            .flatMap(RateOfFireUnit.init(rawValue:)) ?? .rps
        self.autoReconnect = defaults.object(forKey: Keys.autoReconnect) as? Bool ?? true

        // 実機トランスポート (CoreBluetoothTransport) は BLE プロトコル解析が
        // 終わるまで存在しない。それまではリプレイのみで動かす。
        let transport = DemoReplay.makeTransport()
        self.device = ChronoDevice(
            transport: transport,
            decoder: DemoDecoder(),
            store: UserDefaultsKeyValueStore(defaults: defaults),
            configuration: .init(
                nameFilter: nil,
                notifyCharacteristics: [DemoProtocol.characteristic],
                autoReconnect: defaults.object(forKey: Keys.autoReconnect) as? Bool ?? true
            )
        )
    }

    /// SwiftData のコンテキストを渡してイベントの取り込みを始める。View の `.task` から呼ぶ。
    func start(modelContext: ModelContext) {
        if self.modelContext == nil { self.modelContext = modelContext }
        restoreSelectedProfileIfNeeded()
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
        case .battery, .deviceInfo, .raw:
            // プロトコル未確定のうちは届かない。届いても無視して問題ない。
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
        let session = activeSession ?? beginSession(in: modelContext)
        let record = ShotRecord(shot: shot, session: session)
        modelContext.insert(record)
        session.shots.append(record)
        try? modelContext.save()
        recomputeStats()
    }

    /// 最初の 1 発でセッションを自動開始する。
    private func beginSession(in modelContext: ModelContext) -> Session {
        let session = Session(
            startedAt: Date(),
            gunName: gunName,
            bbWeightGrams: massGrams
        )
        modelContext.insert(session)
        activeSession = session
        return session
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
            let profile = GunProfile(name: "マイガン", bbWeightGrams: 0.25)
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
