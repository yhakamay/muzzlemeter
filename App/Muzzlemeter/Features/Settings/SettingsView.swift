import MuzzlemeterKit
import SwiftData
import SwiftUI

/// 表示単位・銃プロファイル・接続の設定。
struct SettingsView: View {
    @Environment(ChronoService.self) private var service
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \GunProfile.createdAt) private var profiles: [GunProfile]

    @State private var editingProfile: GunProfile?
    @State private var isAddingProfile = false
    /// 目視確認の起動引数からプロファイル詳細を開けるように、遷移を値で持つ。
    @State private var path = NavigationPath()

    var body: some View {
        @Bindable var service = service
        @Bindable var feedback = service.feedback

        NavigationStack(path: $path) {
            Form {
                Section("表示単位") {
                    // `.segmented` は Picker のラベルを描かないので、何を切り替えているのか
                    // 分かるように見出しを自前で出す（「RPS / RPM」だけでは意味が読めない）。
                    segmented("弾速") {
                        Picker("弾速", selection: $service.speedUnit) {
                            Text(verbatim: "m/s").tag(SpeedUnit.metersPerSecond)
                            Text(verbatim: "fps").tag(SpeedUnit.feetPerSecond)
                        }
                    }

                    segmented("連射速度") {
                        Picker("連射速度", selection: $service.rateOfFireUnit) {
                            Text(verbatim: "RPS").tag(RateOfFireUnit.rps)
                            Text(verbatim: "RPM").tag(RateOfFireUnit.rpm)
                        }
                    }
                }

                Section {
                    Toggle("超過時の音", isOn: $feedback.isLimitSoundEnabled)
                    Toggle("超過時のハプティクス", isOn: $feedback.isLimitHapticsEnabled)
                } header: {
                    Text("規制上限の通知")
                } footer: {
                    // サイレントスイッチの扱いを明記する。射撃場で音が出るかどうかは
                    // 事前に知っておきたい情報で、鳴ってから驚くのでは遅い。
                    Text("上限に近づいた 1 発（上限の 10 % 以内）と、上限を越えた 1 発を知らせます。音は本体のサイレントスイッチに従います。上限はプロファイルごとに設定できます。")
                }

                Section {
                    Toggle("弾速を読み上げる", isOn: $feedback.isSpeechEnabled)
                    Toggle("ジュールも読み上げる", isOn: $feedback.speaksJoules)
                        .disabled(!feedback.isSpeechEnabled)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("読み上げの速さ")
                            .font(.subheadline)
                        HStack(spacing: 8) {
                            Image(systemName: "tortoise")
                                .foregroundStyle(.secondary)
                            Slider(
                                value: $feedback.speechRate,
                                in: FeedbackService.minimumSpeechRate...FeedbackService.maximumSpeechRate
                            )
                            .disabled(!feedback.isSpeechEnabled)
                            Image(systemName: "hare")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("読み上げ")
                } footer: {
                    // 通知音（サイレントスイッチに従う）と扱いが違うことを明記する。
                    // 「なぜ音は消えるのに読み上げは喋るのか」を後から悩ませない。
                    Text("1 発ごとに、表示している単位のまま弾速を読み上げます。上限を越えた発では「超過」も読み上げます。読み上げは音楽と同じ経路で再生するため、**本体のサイレントスイッチでは消えません**（音楽は少し音量が下がるだけで止まりません）。手も目も離せないときに耳で確認するための機能なので、意図的にこうしてあります。")
                }

                Section {
                    ForEach(profiles) { profile in
                        // タップは編集ではなく**詳細**へ。編集は詳細の「編集」から。
                        // 一覧から直に編集シートを出していた頃は、「この銃はいまどうなって
                        // いるか」を見る場所がどこにも無かった。
                        NavigationLink(value: profile) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.name)
                                    HStack(spacing: 6) {
                                        PowerCategoryBadge(category: profile.powerCategory)
                                        Text(GunProfile.weightLabel(profile.defaultBBWeightGrams))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if profile == service.selectedProfile {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button("使用") { service.selectedProfile = profile }
                                .tint(.blue)
                        }
                        .contextMenu {
                            Button("編集", systemImage: "pencil") { editingProfile = profile }
                        }
                    }
                    .onDelete(perform: deleteProfiles)

                    Button("プロファイルを追加", systemImage: "plus") {
                        isAddingProfile = true
                    }
                } header: {
                    Text("銃プロファイル")
                } footer: {
                    // スワイプの向きは実装と一致させる: 選択は leading（右スワイプ）、
                    // 削除は onDelete（左スワイプ）。逆に書くと破壊的操作に誘導してしまう。
                    Text("プロファイルは銃そのものの情報と、計測条件の既定値を持ちます。タップで詳細（推移と編集）、右スワイプで選択、左スワイプで削除。")
                }

                Section {
                    Toggle("自動再接続", isOn: $service.autoReconnect)
                    Button("この機器を忘れる", systemImage: "xmark.circle", role: .destructive) {
                        service.forgetDevice()
                    }
                    // role: .destructive はラベルだけ赤くしてアイコンはアクセントカラーのまま
                    // なので、赤字＋青アイコンのちぐはぐな行になる。まとめて赤にする。
                    .foregroundStyle(.red)
                } header: {
                    Text("接続")
                } footer: {
                    if service.isReplaying {
                        // プロトコル解析は完了済み（README / docs/PROTOCOL.md）。
                        // 再生になるのはシミュレータに BLE が無いか --replay を付けたときだけ。
                        Text("シミュレータ／`--replay` 起動のため、記録済みパケットのデモ再生で動作しています。実機の AC6000 に繋ぐときは、iPhone 実機で `--replay` を付けずに起動してください。")
                    } else {
                        Text("最後に接続した機器を覚えて、アプリを開いたら自動で繋ぎ直します。")
                    }
                }
            }
            .navigationTitle("設定")
            .navigationDestination(for: GunProfile.self) { profile in
                GunProfileDetailView(profile: profile)
            }
            .task {
                // 目視確認用（Debug のシミュレータのみ）。最初のプロファイルの詳細を開く。
                if ScreenshotSupport.opensProfileDetail, let first = profiles.first {
                    path.append(first)
                }
            }
            .sheet(isPresented: $isAddingProfile) {
                GunProfileEditor(profile: nil) { draft in
                    let profile = draft.makeProfile()
                    modelContext.insert(profile)
                    try? modelContext.save()
                    if service.selectedProfile == nil { service.selectedProfile = profile }
                }
            }
            .sheet(item: $editingProfile) { profile in
                GunProfileEditor(profile: profile) { draft in
                    draft.apply(to: profile)
                    try? modelContext.save()
                }
            }
        }
    }

    /// セグメンテッドピッカーに見出しを添えた 1 行。
    ///
    /// 見出しは `LocalizedStringKey` で受ける。`String` にすると、呼び出し側が書いた
    /// 日本語リテラルがそのまま `Text` に渡って**翻訳されない**（実際に一度そうなった）。
    private func segmented(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
            content()
                .pickerStyle(.segmented)
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private func deleteProfiles(at offsets: IndexSet) {
        for index in offsets {
            let profile = profiles[index]
            if profile == service.selectedProfile { service.selectedProfile = nil }
            modelContext.delete(profile)
        }
        try? modelContext.save()
    }
}

/// 編集中のプロファイルの下書き。
///
/// 項目が増えたので、シートの `onSave` に引数を並べるのをやめて 1 つの値にまとめた。
/// `@Model` の `GunProfile` を編集中のシートに直接渡すと、キャンセルしても
/// 途中の入力がストアへ書き戻ってしまう（SwiftData の変更は即時に反映される）ため、
/// **値型の下書きを編集して、保存のときだけ書き戻す**。
struct GunProfileDraft {
    var name: String = ""
    var manufacturer: String = ""
    var model: String = ""
    var powerCategory: PowerCategory = .electric
    var innerBarrelLengthMm: Int?
    var energyLimitJoules: Double = 0.98
    // 計測の既定値（セッション変数の初期値）。
    var defaultBBWeightGrams: Double = 0.25
    var defaultGasType: GasType = .hfc134a
    var defaultHopSetting: String = ""
    /// 目標発数の既定値。`nil` は「手動で締める」。
    var targetShotCount: Int?
    var notes: String = ""

    init() {}

    init(profile: GunProfile) {
        name = profile.name
        manufacturer = profile.manufacturer
        model = profile.model
        powerCategory = profile.powerCategory
        innerBarrelLengthMm = profile.innerBarrelLengthMm
        energyLimitJoules = profile.energyLimitJoules
        defaultBBWeightGrams = profile.defaultBBWeightGrams
        defaultGasType = profile.defaultGasType
        defaultHopSetting = profile.defaultHopSetting
        targetShotCount = profile.targetShotCount
        notes = profile.notes
    }

    func apply(to profile: GunProfile) {
        profile.name = name
        profile.manufacturer = manufacturer
        profile.model = model
        profile.powerCategory = powerCategory
        profile.innerBarrelLengthMm = innerBarrelLengthMm
        profile.energyLimitJoules = energyLimitJoules
        profile.defaultBBWeightGrams = defaultBBWeightGrams
        profile.defaultGasType = defaultGasType
        profile.defaultHopSetting = defaultHopSetting.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.targetShotCount = targetShotCount
        profile.notes = notes
    }

    func makeProfile() -> GunProfile {
        let profile = GunProfile(name: name, bbWeightGrams: defaultBBWeightGrams)
        apply(to: profile)
        return profile
    }
}

/// プロファイルの新規作成・編集シート。BB 重量はプリセット＋自由入力。
struct GunProfileEditor: View {
    let profile: GunProfile?
    let onSave: (GunProfileDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: GunProfileDraft
    @State private var barrelText: String
    @State private var limitText: String
    @State private var targetShotsText: String

    init(profile: GunProfile?, onSave: @escaping (GunProfileDraft) -> Void) {
        self.profile = profile
        self.onSave = onSave
        let draft = profile.map(GunProfileDraft.init(profile:)) ?? GunProfileDraft()
        _draft = State(initialValue: draft)
        _barrelText = State(initialValue: draft.innerBarrelLengthMm.map(String.init) ?? "")
        _limitText = State(initialValue: String(format: "%.2f", draft.energyLimitJoules))
        _targetShotsText = State(initialValue: draft.targetShotCount.map(String.init) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本") {
                    labeledField("名前", placeholder: "例: 次世代 M4", text: $draft.name)
                    labeledField("メーカー", placeholder: "例: 東京マルイ", text: $draft.manufacturer)
                    labeledField("モデル", placeholder: "例: HK416D", text: $draft.model)
                }

                Section {
                    // セクション見出しが「パワーソース」なので、行の見出しは「区分」にする
                    // （同じ語が 2 段続くと、どちらが何なのか読み取れない）。
                    Picker("区分", selection: $draft.powerCategory) {
                        ForEach(PowerCategory.allCases) { category in
                            Text(category.label).tag(category)
                        }
                    }
                    // ガス種別は**その回ごとに変わる**のでセッション側が本体。ここにあるのは
                    // 新しいセッションを始めるときの初期値なので、ガスのときだけ訊く。
                    if draft.powerCategory.usesGas {
                        Picker("ガス種別の既定値", selection: $draft.defaultGasType) {
                            ForEach(GasType.allCases) { gas in
                                Text(gas.label).tag(gas)
                            }
                        }
                    }
                } header: {
                    Text("パワーソース")
                } footer: {
                    Text("駆動方式は気温での初速の動きかたが違うので、後から見返すときの手掛かりになります。ガス種別はセッションごとに変えられます。")
                }

                Section {
                    HStack {
                        Text("インナーバレル長")
                        Spacer()
                        TextField("未設定", text: $barrelText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 90)
                        Text(verbatim: "mm")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("規制上限")
                        Spacer()
                        TextField("0.98", text: $limitText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 90)
                        Text(verbatim: "J")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("仕様")
                } footer: {
                    Text("規制上限は日本の法令上限 0.98 J が既定です。フィールド独自の上限があるときは、その値に変えられます。")
                }

                Section {
                    BBWeightPicker(grams: $draft.defaultBBWeightGrams)
                    HStack {
                        Text("ホップ")
                        Spacer()
                        TextField("例: 3 / 少し強め", text: $draft.defaultHopSetting)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("目標発数")
                        Spacer()
                        TextField("手動", text: $targetShotsText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 90)
                        Text("発")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("計測の既定値")
                } footer: {
                    Text("新しいセッションはこの条件で始まります。Live 画面から、その回だけ変えることもできます。目標発数を入れると、その発数に届いた時点でセッションが自動的に締まります（空欄なら手動）。")
                }

                Section("メモ") {
                    TextField("スプリング、内部カスタム、注意点など", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle(profile == nil ? "プロファイルを追加" : "プロファイルを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(resolvedDraft)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty || draft.defaultBBWeightGrams <= 0)
                }
            }
        }
    }

    /// 「項目名 : 入力欄」の 1 行。設定アプリと同じ並びにして、入力済みでも
    /// 何の欄なのか分かるようにする（プレースホルダだけだと埋めた瞬間に消える）。
    private func labeledField(
        _ title: LocalizedStringKey,
        placeholder: LocalizedStringKey,
        text: Binding<String>
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
        }
    }

    /// テキスト入力の項目（バレル長・規制上限）を下書きへ畳み込んだもの。
    private var resolvedDraft: GunProfileDraft {
        var resolved = draft
        resolved.name = trimmedName
        resolved.manufacturer = draft.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        resolved.model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        resolved.innerBarrelLengthMm = effectiveBarrelLength
        resolved.energyLimitJoules = effectiveEnergyLimit
        resolved.targetShotCount = effectiveTargetShotCount
        return resolved
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 空欄・0 以下は既定の 0.98 J に戻す（上限 0 J は意味を成さない）。
    private var effectiveEnergyLimit: Double {
        let normalized = limitText
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else { return 0.98 }
        return value
    }

    /// 空欄・0 以下は「手動」にする（`ShotTarget` が成立しない値は持たない）。
    private var effectiveTargetShotCount: Int? {
        ShotTarget(Int(targetShotsText.trimmingCharacters(in: .whitespacesAndNewlines)))?.count
    }

    /// 空欄・0 以下は「未設定」にする（0 mm のバレルは存在しない）。
    private var effectiveBarrelLength: Int? {
        guard let value = Int(barrelText.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
            return nil
        }
        return value
    }
}

#Preview {
    SettingsView()
        .environment(ChronoService(defaults: PreviewSupport.defaults, forceReplay: true))
        .modelContainer(PreviewSupport.container)
}
