import SwiftUI

/// パワーソース区分を 1 語で示す小さなバッジ。
///
/// プロファイル一覧とセッション詳細で同じ見た目を使う。色は区分ごとに固定して、
/// 一覧を上から流し読みしたときに文字を読まなくても区別が付くようにしている。
struct PowerCategoryBadge: View {
    let category: PowerCategory

    var body: some View {
        Text(category.badgeLabel)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: .capsule)
            .foregroundStyle(color)
    }

    private var color: Color {
        switch category {
        case .electric: .blue
        case .springAir: .teal
        case .gas: .green
        case .hpa: .orange
        }
    }
}

#Preview {
    VStack(alignment: .leading) {
        ForEach(PowerCategory.allCases) { category in
            PowerCategoryBadge(category: category)
        }
    }
}
