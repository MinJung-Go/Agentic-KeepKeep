import XCTest
@testable import AgenticKeepKeep

/// 流式拼接是最容易出错的地方（工具参数分片到达、用量的分两次上报）
final class LLMStreamAccumulatorTests: XCTestCase {

    private func toolCallEvent(in events: [LLMStreamEvent]) -> (id: String, name: String, json: String)? {
        for event in events {
            if case .toolCall(let id, let name, let json) = event {
                return (id, name, json)
            }
        }
        return nil
    }

    func testAccumulatesTextDeltas() {
        var accumulator = LLMStreamAccumulator()

        let first = accumulator.consume(.init(text: "好的，"))
        let second = accumulator.consume(.init(text: "我先看看数据。"))

        XCTAssertEqual(first, [.text("好的，")])
        XCTAssertEqual(second, [.text("我先看看数据。")])
        XCTAssertEqual(accumulator.accumulatedText, "好的，我先看看数据。")
    }

    func testReasoningIsSeparateFromText() {
        var accumulator = LLMStreamAccumulator()

        _ = accumulator.consume(.init(reasoning: "用户"))
        _ = accumulator.consume(.init(reasoning: "想增肌"))
        _ = accumulator.consume(.init(text: "明白"))

        XCTAssertEqual(accumulator.accumulatedReasoning, "用户想增肌")
        XCTAssertEqual(accumulator.accumulatedText, "明白")
    }

    func testEmptyDeltasAreIgnored() {
        var accumulator = LLMStreamAccumulator()

        XCTAssertTrue(accumulator.consume(.init(text: "")).isEmpty)
        XCTAssertTrue(accumulator.consume(.init(reasoning: "")).isEmpty)
        XCTAssertTrue(accumulator.consume(.init()).isEmpty)
    }

    func testAssemblesToolCallFromFragments() {
        var accumulator = LLMStreamAccumulator()

        // 参数是分片到达的，必须按 index 拼接
        _ = accumulator.consume(.init(toolCallIndex: 0, toolCallID: "call_1", toolCallName: "create_plan", toolCallArguments: #"{"title":"#))
        _ = accumulator.consume(.init(toolCallIndex: 0, toolCallArguments: #""4 周""#))
        _ = accumulator.consume(.init(toolCallIndex: 0, toolCallArguments: #","weeks":4}"#))

        let events = accumulator.finish()
        let call = toolCallEvent(in: events)

        XCTAssertEqual(call?.id, "call_1")
        XCTAssertEqual(call?.name, "create_plan")
        XCTAssertEqual(call?.json, #"{"title":"4 周","weeks":4}"#)
    }

    func testMultipleToolCallsKeepTheirOwnArguments() {
        var accumulator = LLMStreamAccumulator()

        _ = accumulator.consume(.init(toolCallIndex: 0, toolCallID: "a", toolCallName: "create_plan", toolCallArguments: "{\"title\":"))
        _ = accumulator.consume(.init(toolCallIndex: 1, toolCallID: "b", toolCallName: "propose_plan_adjustment", toolCallArguments: "{\"summary\":"))
        _ = accumulator.consume(.init(toolCallIndex: 0, toolCallArguments: "\"A\"}"))
        _ = accumulator.consume(.init(toolCallIndex: 1, toolCallArguments: "\"B\"}"))

        let calls = accumulator.finish().compactMap { event -> (String, String)? in
            if case .toolCall(_, let name, let json) = event { return (name, json) }
            return nil
        }

        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].0, "create_plan")
        XCTAssertEqual(calls[0].1, #"{"title":"A"}"#)
        XCTAssertEqual(calls[1].0, "propose_plan_adjustment")
        XCTAssertEqual(calls[1].1, #"{"summary":"B"}"#)
    }

    func testToolCallWithoutNameIsDropped() {
        var accumulator = LLMStreamAccumulator()

        _ = accumulator.consume(.init(toolCallIndex: 0, toolCallArguments: "{}"))
        let events = accumulator.finish()

        XCTAssertNil(toolCallEvent(in: events), "没有函数名的调用是无效分片")
    }

    func testEmptyArgumentsBecomeEmptyObject() {
        var accumulator = LLMStreamAccumulator()

        _ = accumulator.consume(.init(toolCallIndex: 0, toolCallName: "create_plan"))
        let call = toolCallEvent(in: accumulator.finish())

        XCTAssertEqual(call?.json, "{}", "无参数时给空对象，避免下游解析崩溃")
    }

    func testUsageSplitAcrossTwoReportsIsMerged() {
        var accumulator = LLMStreamAccumulator()

        // Anthropic：先给输入，再给输出
        accumulator.setUsage(LLMUsage(promptTokens: 1_200, completionTokens: 0, totalTokens: 1_200))
        accumulator.setUsage(LLMUsage(promptTokens: 0, completionTokens: 350, totalTokens: 350))

        let usage = accumulator.finish().compactMap { event -> LLMUsage? in
            if case .usage(let value) = event { return value }
            return nil
        }.first

        XCTAssertEqual(usage?.promptTokens, 1_200)
        XCTAssertEqual(usage?.completionTokens, 350)
        XCTAssertEqual(usage?.totalTokens, 1_550)
    }

    func testNoUsageEventWhenNothingReported() {
        var accumulator = LLMStreamAccumulator()

        _ = accumulator.consume(.init(text: "hi"))
        let events = accumulator.finish()

        XCTAssertFalse(events.contains { if case .usage = $0 { return true }; return false })
    }

    func testFinishAlwaysEndsWithFinishedEvent() {
        var accumulator = LLMStreamAccumulator()
        accumulator.setFinishReason("stop")

        let events = accumulator.finish()

        guard case .finished(let reason)? = events.last else {
            return XCTFail("最后一个事件应当是 finished")
        }
        XCTAssertEqual(reason, "stop")
    }
}
