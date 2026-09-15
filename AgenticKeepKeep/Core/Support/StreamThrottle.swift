import Foundation

/// 流式渲染节流。
///
/// 模型每吐一个 chunk 就重建一次 `AttributedString` 并重排气泡，长回复下主线程会被打满。
/// 这里把刷新合并到固定窗口：**首个 chunk 立刻出**（否则开头会顿一下），之后每个窗口最多刷一次。
///
/// 用法：每到一块内容问一次 `shouldEmit()`；流结束时问一次 `flush()`，
/// 把落在窗口中间、还没推出去的那次补上 —— 不然最后一个字会看不到。
///
/// 纯逻辑，不碰时间以外的任何东西，便于单测。
struct StreamThrottle {

    /// 合并窗口，默认 60ms（设计系统 §10）
    let interval: TimeInterval

    private var lastEmit: Date?
    private var hasPending = false

    init(interval: TimeInterval = 0.06) {
        self.interval = interval
    }

    /// 收到新内容时调用：现在要不要刷新界面
    mutating func shouldEmit(at now: Date = .now) -> Bool {
        hasPending = true

        guard let last = lastEmit else {
            // 第一个 chunk 立即显示
            lastEmit = now
            hasPending = false
            return true
        }

        guard now.timeIntervalSince(last) >= interval else { return false }

        lastEmit = now
        hasPending = false
        return true
    }

    /// 流结束或中断时调用：返回 true 表示还有一次没推出去的更新，调用方补刷一次
    mutating func flush() -> Bool {
        let pending = hasPending
        lastEmit = nil
        hasPending = false
        return pending
    }
}
