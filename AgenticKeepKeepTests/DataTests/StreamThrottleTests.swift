import XCTest
@testable import AgenticKeepKeep

/// 流式节流的纯逻辑。
///
/// 要守住的两件事：**开头不能顿**（第一个 chunk 立刻出）、**结尾不能丢字**
/// （落在窗口中间的那次更新必须在 `flush()` 时补上）。
final class StreamThrottleTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    func testFirstChunkEmitsImmediately() {
        var throttle = StreamThrottle(interval: 0.06)
        XCTAssertTrue(throttle.shouldEmit(at: t0), "第一个 chunk 必须立刻显示，否则开头会顿一下")
    }

    func testChunksInsideWindowAreHeldBack() {
        var throttle = StreamThrottle(interval: 0.06)
        _ = throttle.shouldEmit(at: t0)

        XCTAssertFalse(throttle.shouldEmit(at: t0.addingTimeInterval(0.01)))
        XCTAssertFalse(throttle.shouldEmit(at: t0.addingTimeInterval(0.05)))
    }

    func testEmitsAgainAfterWindow() {
        var throttle = StreamThrottle(interval: 0.06)
        _ = throttle.shouldEmit(at: t0)

        XCTAssertTrue(throttle.shouldEmit(at: t0.addingTimeInterval(0.06)))
        XCTAssertTrue(throttle.shouldEmit(at: t0.addingTimeInterval(0.2)))
    }

    func testWindowRestartsFromLastEmit() {
        var throttle = StreamThrottle(interval: 0.06)
        _ = throttle.shouldEmit(at: t0)
        XCTAssertTrue(throttle.shouldEmit(at: t0.addingTimeInterval(0.06)))

        // 从上次刷新起算，而不是从最开始
        XCTAssertFalse(throttle.shouldEmit(at: t0.addingTimeInterval(0.10)))
        XCTAssertTrue(throttle.shouldEmit(at: t0.addingTimeInterval(0.12)))
    }

    // MARK: - flush

    func testFlushReportsHeldBackUpdate() {
        var throttle = StreamThrottle(interval: 0.06)
        _ = throttle.shouldEmit(at: t0)
        _ = throttle.shouldEmit(at: t0.addingTimeInterval(0.01))   // 被窗口挡住

        XCTAssertTrue(throttle.flush(), "有一次没推出去的更新，调用方要补刷")
    }

    func testFlushIsSilentWhenNothingPending() {
        var throttle = StreamThrottle(interval: 0.06)
        _ = throttle.shouldEmit(at: t0)

        XCTAssertFalse(throttle.flush(), "刚刷过，没有挂起的更新")
    }

    func testFlushResetsSoNextStreamStartsFresh() {
        var throttle = StreamThrottle(interval: 0.06)
        _ = throttle.shouldEmit(at: t0)
        _ = throttle.shouldEmit(at: t0.addingTimeInterval(0.01))
        _ = throttle.flush()

        // 下一轮对话的第一个 chunk 仍然要立刻显示
        XCTAssertTrue(throttle.shouldEmit(at: t0.addingTimeInterval(0.02)))
    }

    func testFlushThenFlushAgainReportsNothing() {
        var throttle = StreamThrottle(interval: 0.06)
        _ = throttle.shouldEmit(at: t0)
        _ = throttle.shouldEmit(at: t0.addingTimeInterval(0.01))

        XCTAssertTrue(throttle.flush())
        XCTAssertFalse(throttle.flush(), "flush 之后不该再报一次")
    }
}
