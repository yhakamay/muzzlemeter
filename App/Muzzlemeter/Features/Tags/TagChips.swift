import MuzzlemeterKit
import SwiftUI

/// タグ 1 個の見た目。押せる（絞り込み・候補）／外せる（編集中）／ただの表示の 3 通り。
///
/// 3 つを別々のビューにすると、角丸・余白・文字サイズが少しずつ食い違って
/// 「同じタグなのに画面ごとに違うもの」に見える。形は 1 箇所で決める。
struct TagChip: View {
    let text: String
    /// 絞り込みで選ばれている状態。地色と文字色が反転する。
    var isSelected = false
    /// 押したときの動作。`nil` なら押せない（ただの表示）。
    var action: (() -> Void)?
    /// × を出して外せるようにする。
    var onRemove: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            Text(verbatim: text)
                .font(.caption)
                .lineLimit(1)
            if let onRemove {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(text) を外す"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.background.secondary),
            in: .capsule
        )
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .contentShape(.capsule)
    }
}

/// タグを**折り返して**並べる。行に入り切らなければ次の行へ落とす。
///
/// 横スクロールにすると、付いているタグの数が画面外に隠れて分からない。
/// 詳細画面と編集シートでは「いま何が付いているか」を一目で数えられることが大事なので、
/// 高さが伸びても折り返す。
struct TagChipRow: View {
    let tags: [String]
    var isSelected: (String) -> Bool = { _ in false }
    var action: ((String) -> Void)?
    var onRemove: ((String) -> Void)?

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                TagChip(
                    text: tag,
                    isSelected: isSelected(tag),
                    action: action.map { handler in { handler(tag) } },
                    onRemove: onRemove.map { handler in { handler(tag) } }
                )
            }
        }
    }
}

/// 折り返す並べかた。`Layout` を自前で書いているのは、SwiftUI に
/// 「入るだけ並べて溢れたら改行する」標準のスタックが無いため。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = layout(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// 何も無いときの既定の候補。
///
/// 「タグを付けてください」と空欄だけ出しても、何を書けばいいのか分からない。
/// **調整の記録として後から効くもの**（内部をいじった / 環境が違う）を最初から並べて、
/// タグの使いどころを例で示す。
enum SessionTagSuggestions {
    static var starters: [String] {
        [
            String(localized: "ホップ強め"),
            String(localized: "ホップ弱め"),
            String(localized: "スプリング交換"),
            String(localized: "新品"),
            String(localized: "フィールド"),
            String(localized: "屋内"),
        ]
    }
}
