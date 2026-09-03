import SwiftUI

/// プロファイルピルの直下に出す「その回の条件」の 1 行。
///
/// `0.25 g · HFC134a · ホップ 3`。**ジュールの根拠**なので常に見えている必要があり、
/// かつ撃っている最中に直したくなる値なので、表示とタップ操作を同じ場所に置く。
struct SessionVariablesLine: View {
    let variables: SessionVariables
    let category: PowerCategory
    var isCompact: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption2)
                Text(verbatim: variables.summary(category: category))
                    .font(isCompact ? .caption : .footnote)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("セッション条件"))
        .accessibilityValue(Text(verbatim: variables.summary(category: category)))
    }
}

/// セッション条件の編集シート。
///
/// **保存ボタンを置かない。** 変えた瞬間に効く（計測中ならセッション全体のジュールが
/// 計算し直される）。モーダルで作業を止めないという UX 原則に合わせ、中くらいの高さで
/// 出して、後ろの Live 画面が見えたままにする。
struct SessionVariablesSheet: View {
    @Environment(ChronoService.self) private var service
    @Environment(\.dismiss) private var dismiss

    @State private var variables: SessionVariables
    /// 待機中だけ出す。ON にすると、いまの条件をプロファイルの既定値にも書き戻す。
    @State private var saveAsDefault = false

    private let category: PowerCategory
    private let isSessionActive: Bool
    private let profileName: String?

    init(service: ChronoService) {
        _variables = State(initialValue: service.variables)
        category = service.powerCategory
        isSessionActive = service.activeSession != nil
        profileName = service.selectedProfile?.name
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    BBWeightPicker(grams: $variables.bbWeightGrams)
                    if category.usesGas {
                        Picker("ガス種別", selection: $variables.gasType) {
                            ForEach(GasType.allCases) { gas in
                                Text(gas.label).tag(gas)
                            }
                        }
                    }
                    HStack {
                        Text("ホップ")
                        Spacer()
                        TextField("例: 3 / 少し強め", text: $variables.hopSetting)
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    if isSessionActive {
                        Text("変更はこのセッション全体に適用され、ジュールが計算し直されます。")
                    } else {
                        Text("次のセッション（最初の 1 発）はこの条件で始まります。")
                    }
                }

                if !isSessionActive, let profileName {
                    Section {
                        Toggle("既定値として保存", isOn: $saveAsDefault)
                    } footer: {
                        Text("プロファイル「\(profileName)」の既定値も、この条件で上書きします。")
                    }
                }

                Section {
                    Button("プロファイルの既定値に戻す", systemImage: "arrow.uturn.backward") {
                        service.resetVariablesToProfileDefaults()
                        variables = service.variables
                        saveAsDefault = false
                    }
                    .disabled(service.variablesMatchProfileDefaults)
                }
            }
            .navigationTitle("セッション条件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            // 保存ボタンが無いので、変更はその場で反映する。
            .onChange(of: variables) { _, new in
                service.variables = new
                if saveAsDefault { service.saveVariablesAsProfileDefaults() }
            }
            .onChange(of: saveAsDefault) { _, isOn in
                if isOn { service.saveVariablesAsProfileDefaults() }
            }
        }
    }
}
