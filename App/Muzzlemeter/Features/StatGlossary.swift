import SwiftUI

/// 統計カードに出る略語の説明。
///
/// SD / ES / RPS は射撃計測の世界では当たり前でも、**エアソフトを始めたばかりの人には
/// 意味が分からない**。数字の横に注釈を常時出すと一瞥性が落ちるので、
/// 項目名をタップしたときだけポップオーバーで出す。
enum StatTerm: String, Identifiable, CaseIterable {
    case mean
    case max
    case min
    case standardDeviation
    case extremeSpread
    case rateOfFire
    case joules
    case energyLimit

    var id: String { rawValue }

    /// 統計カードのセルに出す短い見出し。
    var shortTitle: String {
        switch self {
        case .mean: String(localized: "平均")
        case .max: String(localized: "最大")
        case .min: String(localized: "最小")
        case .standardDeviation: "SD"
        case .extremeSpread: "ES"
        // 連射速度は表示単位（RPS / RPM）そのものを見出しにしているので、
        // ここは説明シートの見出しとしてだけ使う。
        case .rateOfFire: "RPS / RPM"
        case .joules: "J"
        case .energyLimit: String(localized: "上限 / 余裕")
        }
    }

    /// ポップオーバーの見出し。略語には正式名称を添える。
    var title: String {
        switch self {
        case .mean: String(localized: "平均")
        case .max: String(localized: "最大")
        case .min: String(localized: "最小")
        case .standardDeviation: String(localized: "SD（標準偏差）")
        case .extremeSpread: String(localized: "ES（Extreme Spread）")
        case .rateOfFire: String(localized: "RPS / RPM（連射速度）")
        case .joules: String(localized: "J（ジュール）")
        case .energyLimit: String(localized: "規制上限と余裕")
        }
    }

    var detail: String {
        switch self {
        case .mean:
            String(localized: "このセッションで撃った弾の初速の平均です。")
        case .max:
            String(localized: "このセッションで最も速かった 1 発の初速です。")
        case .min:
            String(localized: "このセッションで最も遅かった 1 発の初速です。")
        case .standardDeviation:
            String(localized: "Standard Deviation = 標準偏差。弾速のばらつきの大きさです。標本標準偏差（n−1）で計算しています。値が小さいほど、毎回同じ速度で撃てている＝安定した個体です。")
        case .extremeSpread:
            String(localized: "Extreme Spread = 最大 − 最小。そのセッションで最も速かった弾と最も遅かった弾の差です。1 発の外れ値でも大きくなるので、SD と合わせて見ます。")
        case .rateOfFire:
            String(localized: "Rounds Per Second / Rounds Per Minute = 連射速度。1 秒あたり／1 分あたりの発射数です。単位は設定画面で切り替えられます。「*」が付いているときは、本体から連射速度の報告が無かったため、端末が受け取った時刻の間隔から推定した値です。")
        case .joules:
            String(localized: "初速と BB 重量から計算した運動エネルギー（E = ½mv²）です。重量は選択中のプロファイルの値を使います。")
        case .energyLimit:
            String(localized: "上限はプロファイルごとに決める規制値（日本の法令上限は 0.98 J）です。余裕は「上限 − そのセッションで最も高かった 1 発」で、残りどれだけ出せるかを表します。上限の 10 % 以内に入ると橙色の「注意」、上限に達すると赤色の「超過」になり、音とハプティクスで知らせます（設定で切り替え）。")
        }
    }
}

/// 1 項目分の説明。項目名をタップしたときに出す。
struct StatExplanation: View {
    let term: StatTerm

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(term.title)
                .font(.headline)
            Text(term.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
        .presentationCompactAdaptation(.popover)
    }
}

/// 全項目をまとめた説明。カード見出しの ⓘ から出す。
struct StatGlossary: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("統計の見かた")
                    .font(.headline)
                ForEach(StatTerm.allCases) { term in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(term.title)
                            .font(.subheadline.weight(.semibold))
                        Text(term.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 300, height: 420)
        .presentationCompactAdaptation(.popover)
    }
}
