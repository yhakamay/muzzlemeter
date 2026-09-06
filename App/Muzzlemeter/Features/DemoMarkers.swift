import SwiftUI

/// デモモードの Live 画面まわりの部品（アプリ本体だけで使うもの）。
///
/// 「DEMO」の印そのもの（`DemoBadge` / `DemoMarkerStyle`）は
/// `App/Shared/DemoTag.swift` にある。ウィジェット拡張とも共有するため。

/// Live 画面に出しっぱなしにする帯。**止めかたが同じ場所にある。**
///
/// 入れかたが 1 タップなら、止めかたも 1 タップで、しかも数字の見えている画面から
/// 直接できないといけない。設定タブまで戻らないと止められない状態は、
/// 「デモだと気づかないまま使い続ける」に直結する。
struct DemoModeBanner: View {
    var onExit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "play.rectangle.on.rectangle")
                .foregroundStyle(DemoMarkerStyle.tint)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    DemoBadge()
                    Text("デモモード")
                        .font(.subheadline.weight(.semibold))
                }
                Text("表示している数値は合成した見本で、実測ではありません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("デモモードを終了", action: onExit)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(DemoMarkerStyle.tint)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(DemoMarkerStyle.tint.opacity(0.10), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(DemoMarkerStyle.tint.opacity(0.35))
        }
    }
}

/// 実機を一度も繋いだことがない人に、待機中の Live 画面で出す案内。
///
/// クロノグラフが手元に無いと、この画面は**何も起きない画面**にしかならない。
/// 「壊れている / 使えない」と読まれる前に、その場から試せる道を出す。
struct DemoOfferCard: View {
    var onStart: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("実機が無くても試せます")
                .font(.subheadline.weight(.semibold))
            Text("クロノグラフが手元に無くても、デモモードなら見本の射撃データが流れて、計測中の画面をそのまま確かめられます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("デモモードを試す", systemImage: "play.circle", action: onStart)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(DemoMarkerStyle.tint)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(DemoMarkerStyle.tint.opacity(0.08), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(DemoMarkerStyle.tint.opacity(0.30))
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        DemoBadge()
        DemoModeBanner(onExit: {})
        DemoOfferCard(onStart: {})
    }
    .padding()
}
