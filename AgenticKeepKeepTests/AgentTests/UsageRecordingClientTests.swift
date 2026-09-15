import XCTest
@testable import AgenticKeepKeep

/// 用量装饰器必须**透传**底层事件。
///
/// 背景：`UsageRecordingClient` 一度只实现了 `complete(_:)`，流式调用落到了 `LLMClient`
/// 协议扩展的默认实现上 —— 那个默认实现内部走一次性请求，事件序列里没有 `.reasoning`。
/// 生产路径（教练对话走 `makeRecordingClient()`）因此既拿不到思考内容、也不是真的逐字流式，
/// 而当时的单测 mock 自己实现了 `stream()`，把这条路径整个绕开了。
///
/// 这组用例就是补上那个缺口：**装饰器不能吞事件**。
final class UsageRecordingClientTests: XCTestCase {

    private func collect(_ stream: AsyncThrowingStream<LLMStreamEvent, Error>) async throws -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    // MARK: - 核心回归

    func testStreamForwardsReasoningEvents() async throws {
        let mock = MockLLMClient()
        mock.streamEvents = [
            .reasoning("先看恢复数据，"),
            .reasoning("睡眠只有 6.2 小时。"),
            .text("建议减载。"),
            .finished(reason: "stop")
        ]

        var recorded: [LLMUsage] = []
        let client = UsageRecordingClient(base: mock) { recorded.append($0) }

        let events = try await collect(client.stream(LLMRequest(messages: [.user("我该练什么")])))

        let reasoning = events.compactMap { event -> String? in
            if case .reasoning(let chunk) = event { return chunk }
            return nil
        }
        XCTAssertEqual(
            reasoning,
            ["先看恢复数据，", "睡眠只有 6.2 小时。"],
            "思考内容必须原样透传；为空说明又落回了协议默认实现"
        )

        let text = events.compactMap { event -> String? in
            if case .text(let chunk) = event { return chunk }
            return nil
        }
        XCTAssertEqual(text, ["建议减载。"])
    }

    func testStreamPreservesEventOrderAndToolCalls() async throws {
        let mock = MockLLMClient()
        mock.streamEvents = [
            .reasoning("想一下"),
            .text("给你排个计划"),
            .toolCall(id: "call_1", name: "create_plan", argumentsJSON: #"{"title":"x"}"#),
            .usage(LLMUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15)),
            .finished(reason: "tool_calls")
        ]

        var recorded: [LLMUsage] = []
        let client = UsageRecordingClient(base: mock) { recorded.append($0) }

        let events = try await collect(client.stream(LLMRequest(messages: [.user("增肌")])))

        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events.first, .reasoning("想一下"))
        XCTAssertEqual(events.last, .finished(reason: "tool_calls"))

        guard case .toolCall(let id, let name, let json) = events[2] else {
            return XCTFail("第三个事件应当是工具调用")
        }
        XCTAssertEqual(id, "call_1")
        XCTAssertEqual(name, "create_plan")
        XCTAssertEqual(json, #"{"title":"x"}"#)
    }

    // MARK: - 用量计数

    func testStreamRecordsUsageWithoutDroppingTheEvent() async throws {
        let usage = LLMUsage(promptTokens: 900, completionTokens: 120, totalTokens: 1_020)
        let mock = MockLLMClient()
        mock.streamEvents = [.text("好的"), .usage(usage), .finished(reason: "stop")]

        var recorded: [LLMUsage] = []
        let client = UsageRecordingClient(base: mock) { recorded.append($0) }

        let events = try await collect(client.stream(LLMRequest(messages: [.user("你好")])))

        XCTAssertEqual(recorded, [usage], "用量要回传给设置页做统计")
        XCTAssertTrue(events.contains(.usage(usage)), "用量事件本身也要继续往下传")
    }

    func testCompleteRecordsUsage() async throws {
        let usage = LLMUsage(promptTokens: 30, completionTokens: 8, totalTokens: 38)
        let mock = MockLLMClient(responses: [LLMResponse(content: "ok", toolCalls: [], usage: usage)])

        var recorded: [LLMUsage] = []
        let client = UsageRecordingClient(base: mock) { recorded.append($0) }

        let response = try await client.complete(LLMRequest(messages: [.user("hi")]))

        XCTAssertEqual(response.content, "ok")
        XCTAssertEqual(recorded, [usage])
    }

    func testStreamPropagatesError() async {
        let mock = MockLLMClient()
        mock.streamEvents = [.text("好的")]
        mock.streamError = LLMError.network("断网")

        let client = UsageRecordingClient(base: mock) { _ in }

        do {
            _ = try await collect(client.stream(LLMRequest(messages: [.user("你好")])))
            XCTFail("应当抛出错误")
        } catch let error as LLMError {
            XCTAssertEqual(error, .network("断网"))
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    // MARK: - 一次性路径也要留住思考内容

    func testCompleteKeepsReasoning() async throws {
        let mock = MockLLMClient(responses: [
            LLMResponse(content: "建议减载", toolCalls: [], usage: LLMUsage(), reasoning: "深度思考后的结论")
        ])

        let response = try await mock.complete(LLMRequest(messages: [.user("hi")]))
        XCTAssertEqual(response.reasoning, "深度思考后的结论")
    }

    func testCoachOneShotReplyCarriesReasoning() async throws {
        let mock = MockLLMClient(responses: [
            LLMResponse(content: "这周先减载。", toolCalls: [], usage: LLMUsage(), reasoning: "睡眠不足 + HRV 下行")
        ])

        let reply = try await CoachAgent(client: mock).reply(history: [], userMessage: "要不要减量")

        XCTAssertEqual(reply.text, "这周先减载。")
        XCTAssertEqual(reply.reasoning, "睡眠不足 + HRV 下行", "一次性路径也要把思考内容带出来")
    }

    func testStreamCollectorKeepsReasoningInResponse() async throws {
        let mock = MockLLMClient()
        mock.streamEvents = [
            .reasoning("推理一"),
            .reasoning("推理二"),
            .text("正文"),
            .finished(reason: "stop")
        ]

        let outcome = try await LLMStreamCollector.collect(mock.stream(LLMRequest(messages: [.user("hi")])))

        XCTAssertEqual(outcome.reasoning, "推理一推理二")
        XCTAssertEqual(outcome.response.reasoning, "推理一推理二", "收集成 LLMResponse 时不能丢掉思考内容")
    }

    func testEmptyReasoningBecomesNil() {
        let reply = CoachAgent.makeReply(text: "正文", toolCalls: [], reasoning: "")
        XCTAssertNil(reply.reasoning, "空字符串不应该落库成一段空思考")
        XCTAssertEqual(reply.text, "正文")
    }
}
