import SwiftUI

/// パワーソースを 1 語で示す小さなバッジ。
///
/// プロファイル一覧とセッション詳細で同じ見た目を使う。色は駆動方式ごとに固定して、
/// 一覧を上から流し読みしたときに文字を読まなくても区別が付くようにしている。
struct PowerSourceBadge: View {
    let source: PowerSource

    var body: some View {
        Text(source.badgeLabel)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: .capsule)
            .foregroundStyle(color)
    }

    private var color: Color {
        switch source {
        case .electric: .blue
        case .springAir: .teal
        case .gasHFC134a, .gasHFC152a, .gasGreenGas: .green
        case .gasCO2: .purple
        case .hpa: .orange
        }
    }
}

#Preview {
    VStack(alignment: .leading) {
        ForEach(PowerSource.allCases) { source in
            PowerSourceBadge(source: source)
        }
    }
}
