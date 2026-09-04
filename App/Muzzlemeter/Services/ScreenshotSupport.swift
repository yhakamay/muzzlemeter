import Foundation
import SwiftData

/// スクリーンショット・目視確認のための起動引数。**Debug ビルドのシミュレータでのみ効く。**
///
/// なぜ要るか: 規制上限の色分けや N 発モードのような機能は「特定の値が入っている状態」で
/// ないと見えない。実機を撃たずに、あるいはシミュレータを手で操作せずにその状態を作れないと、
/// 変更のたびに UI を目視確認する手間が現実的でなくなる。
///
/// リリースビルドでは全て `nil` / `false` を返す（引数の解釈すら行わない）ので、
/// 製品の挙動には一切関わらない。
///
/// ```sh
/// xcrun simctl launch <udid> com.yhakamay.muzzlemeter \
///   --replay-capture --demo-energy-limit 0.001 --demo-target-shots 10 \
///   --demo-tab sessions --demo-latest-session
/// ```
enum ScreenshotSupport {
    /// 選択中プロファイルの規制上限を上書きする（J）。
    static var energyLimitOverride: Double? { double(for: "--demo-energy-limit") }

    /// 選択中プロファイルの目標発数を上書きする。`0` で「手動」に戻す。
    static var targetShotCountOverride: Int? { int(for: "--demo-target-shots") }

    /// 起動時に開くタブ（`live` / `sessions` / `settings`）。
    static var initialTab: String? { value(for: "--demo-tab") }

    /// 起動直後に機器選択シートを開く。
    static var opensScanSheet: Bool { flag("--demo-scan-sheet") }

    /// 履歴タブで、いちばん新しいセッションの詳細を開く。
    static var opensLatestSession: Bool { flag("--demo-latest-session") }

    /// 比較・タグ・推移を目視確認するための見本セッションを流し込む。
    static var seedsDemoSessions: Bool { flag("--demo-seed-sessions") }

    /// この起動が始まったおおよその時刻。
    ///
    /// シミュレータでは常に再生が走ってセッションが 1 件できる。見本として入れた
    /// セッションと区別するために、**この起動より前に始まったもの**だけを見本として扱う。
    static let launchedAt = Date()

    /// 履歴タブで、新しい順に 3 件のセッションの比較画面を開く。
    ///
    /// 比較画面は「選択モードに入って 2〜3 件タップして決定」しないと出ない。
    /// シミュレータを手で操作せずにその画面へ行けるようにするための引数。
    static var opensComparison: Bool { flag("--demo-compare") }

    /// 履歴タブで、見本のセッションの詳細を開いてタグ編集シートまで出す。
    static var opensTagEditor: Bool { flag("--demo-tag-editor") }

    /// 履歴タブで、見本のセッションの詳細を開いて条件・銃の編集シートまで出す。
    static var opensConditionsEditor: Bool { flag("--demo-edit-conditions") }

    /// 目視確認用。見本のセッションの BB 重量をこの重量（g）へ直接上書きしてから開く。
    ///
    /// 「BB 重量を変えるとジュールが計算し直される」ことを、タップ操作なしで
    /// 確認するための引数（シミュレータの UI 操作ツールが使えない環境向け）。
    static var appliesBBWeightOverride: Double? { double(for: "--demo-apply-bb-weight") }

    /// セッション詳細を開いたら、統計カード（ジュールが出る場所）までスクロールする。
    ///
    /// `--demo-apply-bb-weight` と組み合わせて使う。統計カードは画面の下の方にあるので、
    /// タップでスクロールできない環境では、ここまで自動で送らないとジュールの変化が
    /// スクリーンショットに写らない。
    static var scrollsToStats: Bool { flag("--demo-scroll-stats") }

    /// 設定タブで、最初のプロファイルの詳細を開く。
    static var opensProfileDetail: Bool { flag("--demo-profile-detail") }

    /// 履歴タブで、このタグの絞り込みを掛けた状態にする。
    static var filterTag: String? { value(for: "--demo-filter") }

    /// 再生用の擬似本体が「持っている」ログ件数（`0x62` の答え）。
    ///
    /// 本体内ログの取り込みは、**本体にログが溜まっていないと帯すら出ない**。
    /// 実機を撃たずにその状態を作るための引数。擬似本体（`ReplayTransport` の
    /// responder）が `0x62` / `0x63` に答えるので、アプリ側は実機と同じ経路を通る。
    static var deviceLogCountOverride: Int? { int(for: "--demo-device-log") }

    /// 擬似本体が返すレコードのうち 1 件を**読めない形**にする。
    /// 「未対応の形式でした」の経路を目視確認するために要る。
    static var deviceLogBrokenIndex: Int? { int(for: "--demo-device-log-broken") }

    /// ライブアクティビティ / Dynamic Island / ホーム画面ウィジェットの見本を
    /// 画面に重ねて出す（`LiveActivityPreviewHost`）。
    ///
    /// シミュレータには「ロックする」「ウィジェットギャラリーを開く」を自動操作する
    /// 手段が無いため、実物と同じ View をアプリの画面内に並べて目視確認する
    /// （Round E、詳細は `LiveActivityPreviewHost` のコメント）。
    static var opensWidgetPreview: Bool { flag("--demo-widgets") }

    /// 件数が分かった時点で、帯を押さずに取り込みを始める。
    ///
    /// 再生は本物のキャプチャ（103 秒 / 6 倍速）なので、**繋がっている時間が
    /// 10 秒足らず**しかない。その間に人の手で「取り込む」を押して進捗を捉えるのは
    /// 運任せになる。押した後の画面（進捗・結果）を毎回同じ手順で出せるようにする。
    static var startsDeviceLogImport: Bool { flag("--demo-device-log-auto") }

    // MARK: - 引数の読み取り

    private static var isEnabled: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private static func value(for key: String) -> String? {
        guard isEnabled else { return nil }
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func flag(_ key: String) -> Bool {
        isEnabled && CommandLine.arguments.contains(key)
    }

    private static func double(for key: String) -> Double? { value(for: key).flatMap(Double.init) }
    private static func int(for key: String) -> Int? { value(for: key).flatMap(Int.init) }
}

// MARK: - 見本セッションの流し込み

extension ScreenshotSupport {
    /// `--demo-seed-sessions` のときだけ、比較・タグ・推移を確認できる見本データを作る。
    ///
    /// 文言は **String Catalog に載せない**（`String(localized:)` を使わない）。
    /// 目視確認用の作りものであって製品の UI 文言ではないので、翻訳の対象に混ぜない。
    ///
    /// 比較画面もタグの絞り込みもプロファイルの推移も、**複数のセッションが
    /// 溜まっていないと画面自体が出ない**。リプレイ再生は 1 セッションしか作らないので、
    /// 目視確認のたびに手で撃ち直す代わりにこれを使う。
    ///
    /// 既にセッションがあるときは何もしない（実データを持っている状態に混ぜない）。
    @MainActor
    static func seedDemoSessionsIfNeeded(modelContext: ModelContext) {
        #if DEBUG && targetEnvironment(simulator)
        _ = launchedAt   // 起動直後の時刻で固定する（再生で増えるセッションと区別するため）
        guard seedsDemoSessions else { return }
        let existing = (try? modelContext.fetchCount(FetchDescriptor<Session>())) ?? 0
        guard existing == 0 else { return }

        let rifle = GunProfile(
            name: "次世代 M4",
            bbWeightGrams: 0.25,
            createdAt: Date().addingTimeInterval(-40 * 86_400),
            powerCategory: .electric,
            defaultHopSetting: "3",
            manufacturer: "東京マルイ",
            model: "HK416D"
        )
        let pistol = GunProfile(
            name: "グロック 18C",
            bbWeightGrams: 0.20,
            createdAt: Date().addingTimeInterval(-30 * 86_400),
            powerCategory: .gas,
            defaultGasType: .hfc134a,
            manufacturer: "東京マルイ",
            model: "G18C"
        )
        modelContext.insert(rifle)
        modelContext.insert(pistol)

        // 気温と弾速の関係が見えるように、**ガス銃は冬と夏で大きく差を付ける**。
        // 電動はホップとスプリングの違いで、ばらつきの大小が比較画面に出るようにする。
        let plans: [DemoSessionPlan] = [
            DemoSessionPlan(
                profile: rifle,
                daysAgo: 21,
                title: "ホップ強めで様子見",
                velocities: [82.1, 83.4, 81.8, 84.0, 82.7, 83.1, 82.4, 83.8],
                temperatureC: 12.4,
                tags: ["ホップ強め", "屋内"]
            ),
            DemoSessionPlan(
                profile: rifle,
                daysAgo: 14,
                title: "ホップ弱めに戻す",
                velocities: [85.2, 86.9, 84.6, 87.3, 85.8, 86.2, 85.1, 86.7, 85.9],
                temperatureC: 18.2,
                tags: ["ホップ弱め", "フィールド"]
            ),
            DemoSessionPlan(
                profile: rifle,
                daysAgo: 5,
                title: "スプリング交換後",
                velocities: [88.9, 89.6, 87.9, 90.2, 88.4, 89.1],
                temperatureC: 24.6,
                tags: ["スプリング交換", "新品"]
            ),
            DemoSessionPlan(
                profile: pistol,
                daysAgo: 18,
                title: "冬の屋内で試射",
                velocities: [78.2, 74.5, 71.0, 68.3, 65.9, 63.1],
                temperatureC: 8.5,
                tags: ["屋内"]
            ),
            DemoSessionPlan(
                profile: pistol,
                daysAgo: 2,
                title: "夏のフィールドで試射",
                velocities: [95.4, 96.8, 94.2, 97.1, 95.9, 96.3],
                temperatureC: 27.8,
                tags: ["フィールド", "新品"]
            ),
        ]

        for plan in plans {
            plan.insert(into: modelContext)
        }
        try? modelContext.save()
        #endif
    }

    /// `--demo-edit-conditions` / `--demo-apply-bb-weight` 用に、終わったセッションを
    /// 1 件専用に作って返す。
    ///
    /// 履歴に溜まった実データや、直前の再生でできたセッションから「それらしいもの」を
    /// 拾おうとすると、**実行のたびに対象が揺れる**（再生の巻き戻し／前回落として
    /// 閉じ忘れたセッション／過去の目視確認で作った見本が入り混じるため）。
    /// 見本を専用に 1 件作って直接返すことで、目視確認を安定させる。
    ///
    /// `seedDemoSessionsIfNeeded` と違って**既存データの有無を問わない**（呼ばれたら
    /// 毎回 1 件足す）。この 2 つの引数を目視確認するときは他の見本を必要としないので、
    /// 履歴が汚れても実害が無い。
    @MainActor
    static func makeConditionsDemoSessionIfNeeded(modelContext: ModelContext) -> Session? {
        #if DEBUG && targetEnvironment(simulator)
        guard opensConditionsEditor || appliesBBWeightOverride != nil else { return nil }
        let profile = GunProfile(
            name: "マイガン",
            bbWeightGrams: 0.25,
            powerCategory: .electric,
            manufacturer: "東京マルイ",
            model: "HK416D"
        )
        modelContext.insert(profile)
        let start = Date().addingTimeInterval(-600)
        let velocities: [Double] = [90.2, 91.5, 89.8, 92.3, 90.9]
        let session = Session(
            startedAt: start,
            endedAt: start.addingTimeInterval(Double(velocities.count) * 2),
            title: "目視確認用セッション",
            gunName: profile.name,
            variables: profile.defaultVariables,
            gunPowerCategory: profile.powerCategory,
            energyLimitJoules: profile.energyLimitJoules,
            gunManufacturer: profile.manufacturer,
            gunModel: profile.model,
            gunInnerBarrelLengthMm: profile.innerBarrelLengthMm
        )
        modelContext.insert(session)
        for (index, velocity) in velocities.enumerated() {
            let record = ShotRecord(
                timestamp: start.addingTimeInterval(Double(index) * 2),
                velocityMetersPerSecond: velocity,
                session: session
            )
            modelContext.insert(record)
            session.shots.append(record)
        }
        try? modelContext.save()
        return session
        #else
        return nil
        #endif
    }
}

/// 見本セッション 1 件分の設計図。
private struct DemoSessionPlan {
    let profile: GunProfile
    let daysAgo: Double
    let title: String
    let velocities: [Double]
    let temperatureC: Double
    let tags: [String]

    @MainActor
    func insert(into modelContext: ModelContext) {
        let start = Date().addingTimeInterval(-daysAgo * 86_400)
        let session = Session(
            startedAt: start,
            endedAt: start.addingTimeInterval(Double(velocities.count) * 2.4),
            title: title,
            gunName: profile.name,
            variables: profile.defaultVariables,
            gunPowerCategory: profile.powerCategory,
            energyLimitJoules: profile.energyLimitJoules,
            gunManufacturer: profile.manufacturer,
            gunModel: profile.model,
            gunInnerBarrelLengthMm: profile.innerBarrelLengthMm
        )
        session.tags = tags
        // 自動取得（WeatherKit）で入った値のように見せる。シミュレータでは実際には
        // 取得できないので、推移画面の散布図を確認するにはここで入れるしかない。
        session.autoTemperatureC = temperatureC
        session.autoHumidity = 0.45 + temperatureC / 200
        session.autoPressureHPa = 1013
        session.weatherFetchedAt = start
        modelContext.insert(session)
        for (index, velocity) in velocities.enumerated() {
            let record = ShotRecord(
                timestamp: start.addingTimeInterval(Double(index) * 2.4),
                velocityMetersPerSecond: velocity,
                session: session
            )
            modelContext.insert(record)
            session.shots.append(record)
        }
    }
}
