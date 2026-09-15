import SwiftUI

/// 横向排列，放不下就换行。
///
/// 胶囊标签宽度不一，用 `LazyVGrid` 的等宽网格会参差不齐；`HStack` 又会溢出。
/// 这个布局按每个子视图的**自身宽度**排，到边界才换行。
struct WrapLayout: Layout {

    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let needed = rowWidth > 0 ? rowWidth + spacing + size.width : size.width

            if rowWidth > 0, needed > maxWidth {
                widestRow = max(widestRow, rowWidth)
                totalHeight += rowHeight + lineSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = needed
                rowHeight = max(rowHeight, size.height)
            }
        }

        widestRow = max(widestRow, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(widestRow, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// 动作胶囊：课程表与教练计划卡共用
struct ExercisePill: View {

    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Font.badge)
            .fontWeight(.regular)
            .foregroundStyle(Theme.secondaryLabel)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, 4)
            .background(Theme.chip, in: Capsule())
    }
}

#Preview {
    WrapLayout {
        ForEach(["卧推 4×8", "哑铃飞鸟 3×12", "双杠臂屈伸 3×10", "绳索下压 3×15", "窄距卧推"], id: \.self) { name in
            ExercisePill(text: name)
        }
    }
    .padding()
    .frame(width: 260)
}
