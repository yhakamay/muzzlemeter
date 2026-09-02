import AceChronoKit
import SwiftData
import SwiftUI

/// 表示単位・銃プロファイル・接続の設定。
struct SettingsView: View {
    @Environment(ChronoService.self) private var service
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \GunProfile.createdAt) private var profiles: [GunProfile]

    @State private var editingProfile: GunProfile?
    @State private var isAddingProfile = false

    var body: some View {
        @Bindable var service = service

        NavigationStack {
            Form {
                Section("表示単位") {
                    // `.segmented` は Picker のラベルを描かないので、何を切り替えているのか
                    // 分かるように見出しを自前で出す（「RPS / RPM」だけでは意味が読めない）。
                    segmented("弾速") {
                        Picker("弾速", selection: $service.speedUnit) {
                            Text("m/s").tag(SpeedUnit.metersPerSecond)
                            Text("fps").tag(SpeedUnit.feetPerSecond)
                        }
                    }

                    segmented("連射速度") {
                        Picker("連射速度", selection: $service.rateOfFireUnit) {
                            Text("RPS").tag(RateOfFireUnit.rps)
                            Text("RPM").tag(RateOfFireUnit.rpm)
                        }
                    }
                }

                Section {
                    ForEach(profiles) { profile in
                        Button {
                            editingProfile = profile
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name)
                                    Text(GunProfile.weightLabel(profile.bbWeightGrams))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if profile == service.selectedProfile {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .swipeActions(edge: .leading) {
                            Button("使用") { service.selectedProfile = profile }
                                .tint(.blue)
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
                    Text("選択中のプロファイルの BB 重量でジュールを計算します。タップで編集、右スワイプで選択、左スワイプで削除。")
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
            .sheet(isPresented: $isAddingProfile) {
                GunProfileEditor(profile: nil) { name, weight in
                    let profile = GunProfile(name: name, bbWeightGrams: weight)
                    modelContext.insert(profile)
                    try? modelContext.save()
                    if service.selectedProfile == nil { service.selectedProfile = profile }
                }
            }
            .sheet(item: $editingProfile) { profile in
                GunProfileEditor(profile: profile) { name, weight in
                    profile.name = name
                    profile.bbWeightGrams = weight
                    try? modelContext.save()
                }
            }
        }
    }

    /// セグメンテッドピッカーに見出しを添えた 1 行。
    private func segmented(_ title: String, @ViewBuilder content: () -> some View) -> some View {
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

/// プロファイルの新規作成・編集シート。BB 重量はプリセット＋自由入力。
struct GunProfileEditor: View {
    let profile: GunProfile?
    let onSave: (String, Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var weight: Double
    @State private var isCustomWeight: Bool
    @State private var customWeightText: String

    init(profile: GunProfile?, onSave: @escaping (String, Double) -> Void) {
        self.profile = profile
        self.onSave = onSave
        let initialWeight = profile?.bbWeightGrams ?? 0.25
        _name = State(initialValue: profile?.name ?? "")
        _weight = State(initialValue: initialWeight)
        _isCustomWeight = State(initialValue: !GunProfile.weightPresets.contains(initialWeight))
        _customWeightText = State(initialValue: String(format: "%.2f", initialWeight))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名前") {
                    TextField("例: 次世代 M4", text: $name)
                }
                Section("BB 重量") {
                    Picker("プリセット", selection: $weight) {
                        ForEach(GunProfile.weightPresets, id: \.self) { preset in
                            Text(GunProfile.weightLabel(preset)).tag(preset)
                        }
                    }
                    .pickerStyle(.wheel)
                    .disabled(isCustomWeight)

                    Toggle("自由入力", isOn: $isCustomWeight)
                    if isCustomWeight {
                        TextField("重量 (g)", text: $customWeightText)
                            .keyboardType(.decimalPad)
                    }
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
                        onSave(trimmedName, effectiveWeight)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty || effectiveWeight <= 0)
                }
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var effectiveWeight: Double {
        guard isCustomWeight else { return weight }
        return Double(customWeightText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }
}

#Preview {
    SettingsView()
        .environment(ChronoService(defaults: PreviewSupport.defaults, forceReplay: true))
        .modelContainer(PreviewSupport.container)
}
