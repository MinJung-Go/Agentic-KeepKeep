import SwiftUI

/// 卡片首次出现：透明度渐入 + 轻微上移，**错峰 40ms**。
///
/// 两条纪律（设计系统 §10）：
/// 1. 位移不超过 8pt —— 这是「出现」，不是「飞入」
/// 2. 开了「减弱动态效果」就完全不做动画，也不做错峰
struct StaggeredAppear: ViewModifier {

    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    /// 错峰间隔。只有几十毫秒 —— 再长用户会等得出来
    private static let step: Double = 0.04

    func body(content: Content) -> some View {
        content
            .opacity(isVisible || reduceMotion ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : 8)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.28).delay(Double(index) * Self.step)) {
                    isVisible = true
                }
            }
    }
}

extension View {

    /// 按顺序渐入。`index` 决定它在错峰序列里的位置。
    func staggeredAppear(_ index: Int) -> some View {
        modifier(StaggeredAppear(index: index))
    }
}

/// 列表插入 / 删除的统一动效
extension Animation {
    static var listChange: Animation { .snappy }
}
