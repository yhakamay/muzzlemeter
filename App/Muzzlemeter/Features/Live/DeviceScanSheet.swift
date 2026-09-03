import MuzzlemeterKit
import SwiftUI

/// 電波強度を 4 本のバーで出す。
///
/// dBm の数字は「−67 は強いのか」が伝わらないので、形で見せる。
/// 数字そのものは補助として小さく添える（電波の様子を追いたい人向け）。
struct SignalBars: View {
    let bars: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { index in
                Capsule()
                    .fill(index <= bars ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: CGFloat(4 + index * 3))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("電波強度"))
        .accessibilityValue(Text("\(bars) / 4"))
    }
}

/// 接続ピルをタップすると出る、見つかった機器の一覧。
///
/// なぜ要るか: 自動接続は「覚えている 1 台」か「最初に見つかった 1 台」に繋ぐ。
/// **複数台の電源が入っている場面**（射撃会・ショップ・友人と並んで測る）では、
/// 意図しない機器に繋がっても気づけず、他人の弾速を自分の記録として保存してしまう。
/// 名前と電波強度を並べて、選び直せるようにする。
///
/// 自動接続そのものは止めない。ここは**上書きするための入口**。
struct DeviceScanSheet: View {
    @Environment(ChronoService.self) private var service
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if service.discovery.isEmpty {
                        emptyRow
                    } else {
                        ForEach(service.discovery.sorted) { peripheral in
                            row(for: peripheral)
                        }
                    }
                } header: {
                    Text("見つかった機器")
                } footer: {
                    Text("電波が強いほど近くにあります。前回つないだ機器には印が付きます。タップするとその機器に繋ぎ直します。")
                }

                Section {
                    Button("もう一度探す", systemImage: "arrow.clockwise") {
                        service.rescan()
                    }
                } footer: {
                    if service.isReplaying {
                        Text("デモ再生では、記録済みの広告から作った擬似的な機器が 1 台だけ見えます。")
                    }
                }
            }
            .navigationTitle("機器を選ぶ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyRow: some View {
        HStack(spacing: 10) {
            if service.connectionState.isBusy {
                ProgressView().controlSize(.small)
                Text("探しています…")
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(.secondary)
                Text("見つかっていません")
            }
        }
        .foregroundStyle(.secondary)
    }

    private func row(for peripheral: DiscoveredPeripheral) -> some View {
        let isRemembered = service.discovery.isRemembered(peripheral)
        return Button {
            service.connect(to: peripheral)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                SignalBars(bars: peripheral.signalBars)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: peripheral.displayName)
                        .font(.body)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if isRemembered {
                            Text("前回接続")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.tint.opacity(0.15), in: .capsule)
                                .foregroundStyle(.tint)
                        }
                        if let rssi = peripheral.rssi {
                            Text(verbatim: "\(rssi) dBm")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .foregroundStyle(.primary)
    }
}
