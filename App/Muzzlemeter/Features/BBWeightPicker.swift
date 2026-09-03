import SwiftUI

/// BB 重量の入力。プリセット＋自由入力。
///
/// プロファイル編集とセッション条件シートで**同じ操作**にするために切り出してある
/// （同じものを 2 つの画面で違う操作にすると、どちらかを覚え直させることになる）。
///
/// 以前はホイールピッカーだったが、セッション条件は中くらいの高さのシートに出す。
/// 160 pt を重量 1 項目に使うと他が押し出されるので、1 行に収まるメニューにした。
/// 自由入力はプリセットの最後の項目として並べ、選ぶと入力欄が現れる。
struct BBWeightPicker: View {
    @Binding var grams: Double

    /// 「自由入力」を表す番兵。実在しない重量なのでプリセットとぶつからない。
    private static let customTag = -1.0

    @State private var isCustom: Bool
    @State private var customText: String

    init(grams: Binding<Double>) {
        _grams = grams
        let isCustom = !GunProfile.weightPresets.contains(grams.wrappedValue)
        _isCustom = State(initialValue: isCustom)
        _customText = State(initialValue: String(format: "%.2f", grams.wrappedValue))
    }

    var body: some View {
        // フォームの 1 行として置けるよう、ピッカーと自由入力欄を 1 つに畳んである
        // （List に custom View を入れると 1 行として扱われるため）。
        VStack(spacing: 10) {
            Picker("BB 重量", selection: selection) {
                ForEach(GunProfile.weightPresets, id: \.self) { preset in
                    Text(verbatim: GunProfile.weightLabel(preset)).tag(preset)
                }
                Text("自由入力").tag(Self.customTag)
            }
            // スタイルは指定しない。`.menu` を明示すると値が青（tint）で描かれ、
            // 隣の「区分」「ガス種別」（自動スタイル＝灰色の値）と食い違って見える。

            if isCustom {
                HStack {
                    Text("重量")
                    Spacer()
                    TextField("0.25", text: $customText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90)
                        .onChange(of: customText) { _, new in
                            if let value = Self.number(new), value > 0 { grams = value }
                        }
                    Text(verbatim: "g")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// ピッカーの選択。自由入力に切り替えたときは、いまの値を入力欄の初期値にする。
    private var selection: Binding<Double> {
        Binding {
            isCustom ? Self.customTag : grams
        } set: { new in
            if new == Self.customTag {
                isCustom = true
                customText = String(format: "%.2f", grams)
            } else {
                isCustom = false
                grams = new
            }
        }
    }

    /// 全角数字やカンマ区切りで入れられても拾う。
    private static func number(_ text: String) -> Double? {
        let normalized = text
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        return Double(normalized)
    }
}
