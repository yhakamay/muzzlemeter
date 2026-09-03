import SwiftUI

/// 本体が選んでいる弾と、セッションの BB 重量が食い違っていることを知らせる帯。
///
/// **作業を止めない。** アラートで出すと、撃っている最中に画面を占領して「OK」を
/// 押させることになる。ジュールが少しずれるだけの話で、計測そのものは続けられるので、
/// 接続ピルの直下に静かに出して、直すか無視するかをその場で選ばせる。
///
/// 本体側の設定は**変えない**（`ChronoService.adoptDeviceAmmoWeight` はセッション側だけを直す）。
struct AmmoMismatchBanner: View {
    let mismatch: ChronoService.AmmoWeightMismatch
    var onAdopt: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.footnote)
                Text(
                    "本体の弾設定 \(GunProfile.weightLabel(mismatch.deviceGrams)) がセッションの \(GunProfile.weightLabel(mismatch.sessionGrams)) と違います"
                )
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.orange)

            HStack(spacing: 10) {
                Button("セッションを \(GunProfile.weightLabel(mismatch.deviceGrams)) にする", action: onAdopt)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("無視", action: onDismiss)
                    .font(.footnote)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
    }
}
