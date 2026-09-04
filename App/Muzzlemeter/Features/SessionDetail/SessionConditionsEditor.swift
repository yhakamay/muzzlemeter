import MuzzlemeterKit
import SwiftData
import SwiftUI

/// `SessionDetailView` の「銃」「セッション条件」を一緒に直すための下書き。
///
/// `GunProfileDraft`（`SettingsView.swift`）と同じ形にしてある。保存ボタンを押すまでは
/// `Session` に一切書き込まない、という操作感を揃えるため。
///
/// **`energyLimitJoules` は持たない。** ユーザーからは「そのセッションが計測時に
/// 適用していた規制上限」を直す対象にしない、という決定（Round D）による。上限を
/// 直したいときはプロファイル側の規制上限を直し、次のセッションから効かせる。
struct SessionConditionsDraft {
    var gunName: String
    var gunManufacturer: String
    var gunModel: String
    var gunPowerCategory: PowerCategory
    var gunInnerBarrelLengthMm: Int?
    var variables: SessionVariables

    init(session: Session) {
        gunName = session.gunName
        gunManufacturer = session.gunManufacturer
        gunModel = session.gunModel
        // 旧スキーマ・移行前のセッションは区分が空のことがある。編集の起点としては
        // 「電動」を仮に置く（プロファイル新規作成時の既定値と同じ）。
        gunPowerCategory = session.gunPowerCategory ?? .electric
        gunInnerBarrelLengthMm = session.gunInnerBarrelLengthMm
        variables = session.variables
    }

    /// プロファイルから**銃情報だけ**を読み込む。BB 重量・ガス種別・ホップには触れない
    /// （選んだ銃と、その回に何を詰めて撃ったかは別の話なので）。
    mutating func adoptGunInfo(from profile: GunProfile) {
        gunName = profile.name
        gunManufacturer = profile.manufacturer
        gunModel = profile.model
        gunPowerCategory = profile.powerCategory
        gunInnerBarrelLengthMm = profile.innerBarrelLengthMm
    }

    /// `session` へ書き込む。**プロファイルへは一切書き戻さない**（スナップショットの
    /// 意味を保つため）。`energyLimitJoules` にも触れない。
    func apply(to session: Session) {
        session.gunName = gunName
        session.gunManufacturer = gunManufacturer
        session.gunModel = gunModel
        session.gunPowerCategoryRaw = gunPowerCategory.rawValue
        session.gunInnerBarrelLengthMm = gunInnerBarrelLengthMm
        session.variables = variables
    }
}

/// セッション詳細の「銃」「セッション条件」セクションを一緒に編集するシート。
///
/// **保存ボタンがある。** Live 画面の条件シート（`SessionVariablesSheet`）はその場で
/// 反映されるが、あちらは「いま計測中の対象を直す」という前提だから成立する即時反映。
/// ここは**終わったセッションの記録を訂正する**場所なので、`SessionEnvironmentEditor`
/// と同じ「キャンセルすれば何も起きない」操作感に揃える。
struct SessionConditionsEditor: View {
    let session: Session

    @Environment(\.dismiss) private var dismiss
    @Environment(ChronoService.self) private var service
    @Query(sort: \GunProfile.createdAt) private var profiles: [GunProfile]

    @State private var draft: SessionConditionsDraft
    @State private var barrelText: String

    init(session: Session) {
        self.session = session
        let draft = SessionConditionsDraft(session: session)
        _draft = State(initialValue: draft)
        _barrelText = State(initialValue: draft.gunInnerBarrelLengthMm.map(String.init) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if !profiles.isEmpty {
                    Section {
                        Menu {
                            ForEach(profiles) { profile in
                                Button(profile.name) { adopt(profile) }
                            }
                        } label: {
                            Label("プロファイルから読み込む", systemImage: "arrow.down.doc")
                        }
                    } footer: {
                        Text("選ぶと、名前・メーカー / モデル・インナーバレル長・区分をそのプロファイルの値で上書きします。BB 重量やガス種別、下のセッション条件は変わりません。")
                    }
                }

                Section {
                    labeledField("名前", placeholder: "例: 次世代 M4", text: $draft.gunName)
                    labeledField("メーカー", placeholder: "例: 東京マルイ", text: $draft.gunManufacturer)
                    labeledField("モデル", placeholder: "例: HK416D", text: $draft.gunModel)
                    Picker("区分", selection: $draft.gunPowerCategory) {
                        ForEach(PowerCategory.allCases) { category in
                            Text(category.label).tag(category)
                        }
                    }
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
                } header: {
                    Text("銃")
                } footer: {
                    Text("この銃を登録したプロファイルが後で変わっても、このセッションの記録は変わりません。プロファイルがもう無い（本体ログからの取り込みなど）ときは、ここで直接直せます。")
                }

                Section {
                    BBWeightPicker(grams: $draft.variables.bbWeightGrams)
                    if draft.gunPowerCategory.usesGas {
                        Picker("ガス種別", selection: $draft.variables.gasType) {
                            ForEach(GasType.allCases) { gas in
                                Text(gas.label).tag(gas)
                            }
                        }
                    }
                    HStack {
                        Text("ホップ")
                        Spacer()
                        TextField("例: 3 / 少し強め", text: $draft.variables.hopSetting)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("セッション条件")
                } footer: {
                    Text("BB 重量を変えると、このセッションの統計・ジュール・CSV がすべて計算し直されます。規制上限（\(GunProfile.energyLimitLabel(session.energyLimitJoules))）は計測時に適用していた値のままです。")
                }
            }
            .navigationTitle("条件と銃を編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty || draft.variables.bbWeightGrams <= 0)
                }
            }
        }
    }

    private func adopt(_ profile: GunProfile) {
        draft.adoptGunInfo(from: profile)
        barrelText = draft.gunInnerBarrelLengthMm.map(String.init) ?? ""
    }

    private var trimmedName: String {
        draft.gunName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        var resolved = draft
        resolved.gunName = trimmedName
        resolved.gunManufacturer = draft.gunManufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        resolved.gunModel = draft.gunModel.trimmingCharacters(in: .whitespacesAndNewlines)
        resolved.gunInnerBarrelLengthMm = effectiveBarrelLength
        resolved.apply(to: session)
        service.saveEditedSession(session)
    }

    /// 空欄・0 以下は「未設定」にする（0 mm のバレルは存在しない）。
    private var effectiveBarrelLength: Int? {
        guard let value = Int(barrelText.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
            return nil
        }
        return value
    }

    /// 「項目名 : 入力欄」の 1 行。`GunProfileEditor` と同じ並びにしてある。
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
}

#Preview {
    SessionConditionsEditor(session: PreviewSupport.sampleSession)
        .environment(ChronoService(defaults: PreviewSupport.defaults, forceReplay: true))
        .modelContainer(PreviewSupport.container)
}
