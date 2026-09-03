import SwiftData
import SwiftUI

/// 環境値の整形。表示は全部ここを通す（画面ごとに桁数がぶれないように）。
enum EnvironmentFormat {
    /// `23.4 ℃`。0.1 ℃ 刻み。気温は 1 度違えばガス銃の初速が変わるので小数第 1 位まで出す。
    static func temperature(_ celsius: Double) -> String {
        String(format: "%.1f ℃", celsius)
    }

    /// `58 %`。保存は 0–1 なので 100 倍する。
    static func humidity(_ fraction: Double) -> String {
        String(format: "%.0f %%", fraction * 100)
    }

    /// `1013 hPa`。1 hPa より細かい値を出しても読む意味が無い。
    static func pressure(_ hPa: Double) -> String {
        String(format: "%.0f hPa", hPa)
    }

    /// 一覧行に添える短い気温（`23℃`）。狭いので単位との間も詰める。
    static func compactTemperature(_ celsius: Double) -> String {
        String(format: "%.0f℃", celsius)
    }
}

/// セッション詳細の「環境」セクション。
///
/// 自動取得（WeatherKit）と手動の上書きが混在するので、**値ごとに出所を出す**。
/// どれが観測値でどれが自分で入れた値なのかが分からないと、後から数字を比べられない。
struct SessionEnvironmentSection: View {
    let session: Session
    @Binding var isEditing: Bool

    /// Apple の要求する帰属表示のリンク先。
    private let attributionURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!

    var body: some View {
        Section {
            if session.hasEnvironmentData {
                if let temperature = session.temperatureC {
                    EnvironmentRow(
                        title: "気温",
                        value: EnvironmentFormat.temperature(temperature),
                        isManual: session.isTemperatureManual
                    )
                }
                if let humidity = session.humidity {
                    EnvironmentRow(
                        title: "湿度",
                        value: EnvironmentFormat.humidity(humidity),
                        isManual: session.isHumidityManual
                    )
                }
                if let pressure = session.pressureHPa {
                    EnvironmentRow(
                        title: "気圧",
                        value: EnvironmentFormat.pressure(pressure),
                        isManual: session.isPressureManual
                    )
                }
                if let condition = session.autoConditionText {
                    EnvironmentRow(
                        title: "天気",
                        value: condition,
                        isManual: false,
                        symbol: session.autoConditionSymbol
                    )
                }
                if let place = session.placeName {
                    EnvironmentRow(title: "場所", value: place, isManual: false)
                }
                if let notes = session.manualNotes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("メモ")
                                .foregroundStyle(.secondary)
                            Spacer()
                            EnvironmentSourceTag(isManual: true)
                        }
                        Text(notes)
                    }
                }
                if session.hasAutoWeather {
                    attribution
                }
            } else {
                // 取れなかった理由はいくつもある（未許可・オフライン・圏外）。
                // 原因を推測して書くより、手で入れられることを示すほうが役に立つ。
                Text("環境の記録がありません。「編集」から手で入力できます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("環境")
                Spacer()
                Button("編集") { isEditing = true }
                    .font(.caption.weight(.semibold))
                    .textCase(nil)
            }
        }
    }

    /// Apple Weather の帰属表示。自動取得の値を出しているときは必ず添える。
    private var attribution: some View {
        Link(destination: attributionURL) {
            HStack(spacing: 3) {
                Image(systemName: "apple.logo")
                Text(verbatim: "Weather")
                Spacer()
                Image(systemName: "arrow.up.right")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

/// 「気温 ─ 23.4 ℃ ─ 自動」の 1 行。
private struct EnvironmentRow: View {
    let title: LocalizedStringKey
    let value: String
    let isManual: Bool
    var symbol: String?

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.multicolor)
                }
                Text(value)
                    .monospacedDigit()
                EnvironmentSourceTag(isManual: isManual)
            }
        } label: {
            Text(title)
        }
    }
}

/// 値の出所を示す小さなタグ。
struct EnvironmentSourceTag: View {
    let isManual: Bool

    var body: some View {
        Text(isManual ? "手動" : "自動")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background((isManual ? Color.orange : Color.secondary).opacity(0.16), in: .capsule)
            .foregroundStyle(isManual ? Color.orange : Color.secondary)
    }
}

/// 環境値を手で上書きするシート。
///
/// 自動値は**消さない**。空欄にすれば自動値に戻る、という 1 つの規則で
/// 「上書きする」と「やめる」を同じ操作にしてある。
struct SessionEnvironmentEditor: View {
    let session: Session

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var temperatureText: String
    @State private var humidityText: String
    @State private var pressureText: String
    @State private var notes: String

    init(session: Session) {
        self.session = session
        _temperatureText = State(initialValue: session.manualTemperatureC.map { String(format: "%.1f", $0) } ?? "")
        _humidityText = State(initialValue: session.manualHumidity.map { String(format: "%.0f", $0 * 100) } ?? "")
        _pressureText = State(initialValue: session.manualPressureHPa.map { String(format: "%.0f", $0) } ?? "")
        _notes = State(initialValue: session.manualNotes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field(
                        title: "気温",
                        unit: "℃",
                        auto: session.autoTemperatureC.map { String(format: "%.1f", $0) },
                        text: $temperatureText,
                        keyboard: .numbersAndPunctuation
                    )
                    field(
                        title: "湿度",
                        unit: "%",
                        auto: session.autoHumidity.map { String(format: "%.0f", $0 * 100) },
                        text: $humidityText,
                        keyboard: .numberPad
                    )
                    field(
                        title: "気圧",
                        unit: "hPa",
                        auto: session.autoPressureHPa.map { String(format: "%.0f", $0) },
                        text: $pressureText,
                        keyboard: .numberPad
                    )
                } header: {
                    Text("手動で上書き")
                } footer: {
                    Text("空欄にすると、その項目は自動取得した値に戻ります。薄い文字は自動値です。")
                }

                Section {
                    TextField("例: 屋内レンジ、風なし", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("メモ")
                } footer: {
                    Text("屋内 / 屋外、風、日射など、数値にならない条件を残せます。")
                }

                Section {
                    Button("すべて自動値に戻す", systemImage: "arrow.uturn.backward", role: .destructive) {
                        temperatureText = ""
                        humidityText = ""
                        pressureText = ""
                        notes = ""
                    }
                    // `role: .destructive` はアイコンをアクセントカラーのまま残すので
                    // まとめて赤にする。ただし無効時は赤いままだと押せそうに見える。
                    .foregroundStyle(hasAnyOverride ? Color.red : Color.secondary)
                    .disabled(!hasAnyOverride)
                }
            }
            .navigationTitle("環境を編集")
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
                }
            }
        }
    }

    private var hasAnyOverride: Bool {
        !temperatureText.isEmpty || !humidityText.isEmpty || !pressureText.isEmpty || !notes.isEmpty
    }

    /// 「項目名 ─ 入力欄 ─ 単位」の 1 行。プレースホルダに自動値を出すことで、
    /// 上書きしようとしている相手が何なのかをその場で見せる。
    private func field(
        title: LocalizedStringKey,
        unit: String,
        auto: String?,
        text: Binding<String>,
        keyboard: UIKeyboardType
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(auto ?? String(localized: "未設定"), text: text)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
            Text(verbatim: unit)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
    }

    private func save() {
        session.manualTemperatureC = Self.number(temperatureText)
        session.manualHumidity = Self.number(humidityText).map { $0 / 100 }
        session.manualPressureHPa = Self.number(pressureText)
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        session.manualNotes = trimmed.isEmpty ? nil : trimmed
        try? modelContext.save()
    }

    /// 全角数字やカンマ区切りで入れられても拾えるようにしておく。
    private static func number(_ text: String) -> Double? {
        let normalized = text
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        guard !normalized.isEmpty else { return nil }
        return Double(normalized)
    }
}
