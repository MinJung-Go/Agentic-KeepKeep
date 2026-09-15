import UIKit

/// 统一的触感反馈。iOS 上「有反馈」是丝滑感的重要来源，集中在一处便于统一节奏。
enum Haptics {

    /// 轻点：切换状态、选中
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 成功：保存、完成训练
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// 警告：删除、失败
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// 选择变化：分段控件、筛选
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
