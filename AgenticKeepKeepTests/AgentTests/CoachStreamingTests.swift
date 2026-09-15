import XCTest
@testable import AgenticKeepKeep

/// 教练流式回复：逐字渲染 + 思考内容 + 工具调用在结束时给出
final class CoachStreamingTests: XCTestCase {

    private func collect(_ stream: AsyncThrowingStream<CoachAgent.StreamEvent, Error>) async throws
        -> (reasoning: String, text: String, reply: CoachReply?) {

        var reasoning = ""
        var text = ""
        var reply: CoachReply?

        for try await event in stream {
            switch event {
            case .reasoning(let chunk): reasoning += chunk
            case .text(let chunk): text += chunk
            case .completed(let value): reply = value
            }
        }

        return (reasoning, text, reply)
    }

    func testStreamsReasoningTextAndPlanDraft() async throws {
        let mock = MockLLMClient()
        mock.streamEvents = [
            .reasoning("用户想增肌，"),
            .reasoning("先看训练与恢复数据。"),
            .text("好的，"),
            .text("我给你排一个 4 周计划。"),
            .toolCall(
                id: "call_1",
                name: "create_plan",
                argumentsJSON: #"{"title":"4 周哑铃增肌","goal":"muscleGain","weeks":4,"days":[]}"#
            ),
            .usage(LLMUsage(promptTokens: 900, completionTokens: 120, totalTokens: 1_020)),
            .finished(reason: "tool_calls")
        ]

        let agent = CoachAgent(client: mock)
        let result = try await collect(agent.streamReply(history: [], userMessage: "我想增肌"))

        XCTAssertEqual(result.reasoning, "用户想增肌，先看训练与恢复数据。")
        XCTAssertEqual(result.text, "好的，我给你排一个 4 周计划。")
        XCTAssertEqual(result.reply?.planDraft?.title, "4 周哑铃增肌")
        XCTAssertNotNil(result.reply?.planArgumentsJSON, "待确认计划要带上原始 JSON 供落库")
    }

    func testStreamsAdjustmentDraft() async throws {
        let mock = MockLLMClient()
        mock.streamEvents = [
            .text("建议减载。"),
            .toolCall(
                id: "call_2",
                name: "propose_plan_adjustment",
                argumentsJSON: #"{"summary":"睡眠不足","changes":[{"dayOffset":2,"action":"deload","detail":"降 15%"}]}"#
            ),
            .finished(reason: "tool_calls")
        ]

        let agent = CoachAgent(client: mock)
        let result = try await collect(agent.streamReply(history: [], userMessage: "最近很累"))

        XCTAssertEqual(result.reply?.adjustmentDraft?.changes.first?.action, "deload")
        XCTAssertNotNil(result.reply?.adjustmentArgumentsJSON)
    }

    func testPlainTextStreamCompletes() async throws {
        let mock = MockLLMClient()
        mock.streamEvents = [
            .text("你每周能练几天？"),
            .finished(reason: "stop")
        ]

        let agent = CoachAgent(client: mock)
        let result = try await collect(agent.streamReply(history: [], userMessage: "我想练力量"))

        XCTAssertEqual(result.reply?.text, "你每周能练几天？")
        XCTAssertNil(result.reply?.planDraft)
    }

    func testEmptyStreamThrows() async {
        let mock = MockLLMClient()
        mock.streamEvents = [.finished(reason: "stop")]

        let agent = CoachAgent(client: mock)

        do {
            _ = try await collect(agent.streamReply(history: [], userMessage: "你好"))
            XCTFail("空回复应当报错")
        } catch let error as AgentError {
            XCTAssertEqual(error, .emptyResponse)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testStreamFailurePropagates() async {
        let mock = MockLLMClient()
        mock.streamEvents = [.text("好的")]
        mock.streamError = LLMError.network("断网")

        let agent = CoachAgent(client: mock)

        do {
            _ = try await collect(agent.streamReply(history: [], userMessage: "你好"))
            XCTFail("应当抛出错误")
        } catch let error as LLMError {
            XCTAssertEqual(error, .network("断网"))
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testThinkingFlagPassedToRequest() async throws {
        let mock = MockLLMClient()
        mock.streamEvents = [.text("好的"), .finished(reason: "stop")]

        let agent = CoachAgent(client: mock)
        _ = try await collect(agent.streamReply(history: [], userMessage: "你好", thinkingEnabled: true))

        XCTAssertEqual(mock.streamRequests.last?.thinkingEnabled, true)
    }

    func testThinkingFlagExplicitlyDisabled() async throws {
        let mock = MockLLMClient()
        mock.streamEvents = [.text("好的"), .finished(reason: "stop")]

        let agent = CoachAgent(client: mock)
        _ = try await collect(agent.streamReply(history: [], userMessage: "你好", thinkingEnabled: false))

        XCTAssertEqual(mock.streamRequests.last?.thinkingEnabled, false, "关闭时明确传递 false，避免服务商默认开启推理")
    }

    func testProfileContextReachesSystemPrompt() async throws {
        let mock = MockLLMClient()
        mock.streamEvents = [.text("好的"), .finished(reason: "stop")]

        var context = CoachContext()
        context.profileText = "【训练】近 28 天 8 次\n【恢复】日均睡眠 6.4h（最低 5.1h）"

        let agent = CoachAgent(client: mock)
        _ = try await collect(agent.streamReply(history: [], userMessage: "我该练什么", context: context))

        let system = try XCTUnwrap(mock.streamRequests.last?.messages.first?.content)
        XCTAssertTrue(system.contains("日均睡眠 6.4h"), "个人数据要进 system prompt")
        XCTAssertTrue(system.contains("引用具体数字"), "要要求模型引用数据")
    }

    func testHistoryIncludedInStreamRequest() async throws {
        let mock = MockLLMClient()
        mock.streamEvents = [.text("好的"), .finished(reason: "stop")]

        let agent = CoachAgent(client: mock)
        _ = try await collect(agent.streamReply(
            history: [
                CoachTurn(role: .user, content: "我想增肌"),
                CoachTurn(role: .assistant, content: "每周能练几天？")
            ],
            userMessage: "4 天"
        ))

        let messages = try XCTUnwrap(mock.streamRequests.last?.messages)
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[1].content, "我想增肌")
        XCTAssertEqual(messages[3].content, "4 天")
    }
}
