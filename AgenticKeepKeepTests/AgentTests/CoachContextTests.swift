import XCTest
@testable import AgenticKeepKeep

/// Extractive scripted client: no credentials/network; supplies only grounded quotes.
final class ContextScriptClient: LLMClient {
    let config = LLMClientConfig(baseURL: "https://fixture.invalid/v1", apiKey: "fixture", model: "fixture")
    var requests: [LLMRequest] = []
    var summaryRequests: [LLMRequest] = []
    var failures: [Error] = []
    var summaryError: Error?
    var maliciousSummary = false
    var omitFacts = false
    var streamPrefix: [LLMStreamEvent] = []
    var stopReason: String? = "stop"
    var summaryDelay: UInt64 = 0

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        if request.jsonMode {
            summaryRequests.append(request)
            if summaryDelay > 0 { try await Task.sleep(nanoseconds: summaryDelay) }
            if let summaryError { throw summaryError }
            let content = request.messages.last!.content
            let payload = content.components(separatedBy: "新资料：\n").last!
            let sources = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [[String: Any]]
            var facts: [[String: String]] = []
            for source in sources {
                let value = source["content"] as! String
                if !omitFacts, value.contains("限制："), source["role"] as? String == "user" {
                    let quote = value.components(separatedBy: "\n").first!
                    facts.append(["sourceID": source["sourceID"] as! String, "quote": maliciousSummary ? "虚构的伤病" : quote])
                }
            }
            let data = try JSONSerialization.data(withJSONObject: ["facts": facts])
            return .text(String(decoding: data, as: UTF8.self), usage: LLMUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15))
        }
        requests.append(request)
        if !failures.isEmpty { throw failures.removeFirst() }
        return LLMResponse(content: "已结合近期数据", finishReason: stopReason)
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for event in streamPrefix { continuation.yield(event) }
                do {
                    let response = try await complete(request)
                    continuation.yield(.text(response.content ?? ""))
                    continuation.yield(.finished(reason: response.finishReason))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class CoachContextTests: XCTestCase {
    private let policy = CoachContextPolicy()
    private let overflow = LLMError.http(status: 400, body: "context_length_exceeded")

    func history(_ count: Int) -> [CoachTurn] {
        (0..<count).flatMap { index in
            let text = index == 0 ? "限制：膝盖旧伤，避免跳跃。\n" : ""
            return [CoachTurn(role: .user, content: text + String(repeating: "训练记录仅供参考。", count: 18), id: UUID(), date: Date(timeIntervalSince1970: Double(index * 2))),
                    CoachTurn(role: .assistant, content: String(repeating: "请按状态安排休息。", count: 18), id: UUID(), date: Date(timeIntervalSince1970: Double(index * 2 + 1)))]
        }
    }

    func testBudgetsIncludeToolsCurrentInputAndOutputReserve() throws {
        let basic = LLMRequest(messages: [.system("规则"), .user("深蹲")], maxTokens: 4_096)
        var toolRequest = basic
        toolRequest.tools = [CoachAgent.createPlanTool]
        XCTAssertGreaterThan(policy.tokens(toolRequest), policy.tokens(basic))
        var small = policy; small.window = 8_192
        XCTAssertLessThan(try small.inputLimit(), try policy.inputLimit())
        var invalid = policy; invalid.window = 4_096
        XCTAssertThrowsError(try invalid.inputLimit())
        let count = policy.tokens(basic)
        var exact = policy; exact.inputCap = count
        XCTAssertNoThrow(try exact.validate(basic))
        exact.inputCap = count - 1
        XCTAssertThrowsError(try exact.validate(basic))
        XCTAssertGreaterThan(policy.estimator.count("中文🙂"), policy.estimator.count("abc"))
        XCTAssertLessThan(try policy.inputLimit(retrying: true), try policy.inputLimit())
    }

    func testLocalSixteenKCanPrepareInitialToolRequest() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = LLMSettings(defaults: defaults)
        settings.useLocalModel = true
        let tools = CoachTools(webSearchEnabled: true, execute: { _ in CoachToolResult(content: "测试") })
        let prepared = try await CoachContextEngine(client: ContextScriptClient(), policy: settings.coachPolicy,
                                                    queryTools: tools.definitions).prepare(
            history: [], userMessage: "今天走了多少步？", context: CoachContext(), memory: nil, thinking: false)
        try settings.coachPolicy.validate(prepared.request)
        XCTAssertEqual(settings.coachPolicy.window, 16_384)
        XCTAssertTrue(Set(tools.definitions.map(\.name)).isSubset(of: Set(prepared.request.tools.map(\.name))))
        XCTAssertEqual(prepared.request.maxTokens, 2048)
    }

    func testShortChatHasNoSummaryAndThinkingReservesActualOutput() async throws {
        let client = ContextScriptClient()
        let result = try await CoachContextEngine(client: client).prepare(history: [], userMessage: "你好", context: CoachContext(), memory: nil, thinking: true)
        XCTAssertTrue(client.summaryRequests.isEmpty)
        XCTAssertEqual(result.request.maxTokens, policy.outputReserve)
        XCTAssertEqual(result.request.thinkingEnabled, true)
        try policy.validate(result.request)
    }

    func testOversizedCurrentInputNeverCallsModelOrTruncates() async {
        let client = ContextScriptClient()
        do {
            _ = try await CoachAgent(client: client).reply(history: history(100), userMessage: String(repeating: "长", count: 20_000))
            XCTFail("必须拒绝超大当前输入")
        } catch { XCTAssertEqual(error as? CoachContextError, .tooLarge) }
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertTrue(client.summaryRequests.isEmpty)
    }

    func testTenHundredAndFiveHundredRoundsStayBoundedAndCacheIsReused() async throws {
        for count in [10, 100, 500] {
            let client = ContextScriptClient(), history = history(count)
            let engine = CoachContextEngine(client: client)
            let started = Date()
            let first = try await engine.prepare(history: history, userMessage: "今天练什么", context: CoachContext(), memory: nil, thinking: false)
            try policy.validate(first.request)
            XCTAssertTrue(first.request.messages.map(\.content).joined().contains("膝盖旧伤"))
            XCTAssertEqual(first.request.messages.filter { $0.content == "今天练什么" }.count, 1)
            for request in client.summaryRequests { try policy.validate(request) }
            let calls = client.summaryRequests.count
            XCTAssertGreaterThan(calls, 0)
            XCTAssertLessThan(calls, count, "应批量处理，而不是每轮一次摘要")
            let second = try await engine.prepare(history: history, userMessage: "今天练什么", context: CoachContext(), memory: first.memory, thinking: false)
            XCTAssertEqual(client.summaryRequests.count, calls)
            XCTAssertEqual(first.request.messages, second.request.messages)
            print("CONTEXT_BENCH rounds=\(count) summaries=\(calls) estimated=\(policy.tokens(first.request)) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        }
    }

    func testHugeOldRoundIsSplitInsteadOfTruncated() async throws {
        let client = ContextScriptClient()
        let old = CoachTurn(role: .user, content: String(repeating: "历史训练数据。", count: 2_000), id: UUID())
        let prepared = try await CoachContextEngine(client: client).prepare(history: [old], userMessage: "继续", context: CoachContext(), memory: nil, thinking: false)
        XCTAssertGreaterThan(client.summaryRequests.count, 1)
        XCTAssertEqual(prepared.memory?.coveredCount, 1)
        try policy.validate(prepared.request)
        for request in client.summaryRequests { try policy.validate(request) }
    }

    func testFabricatedFactIsRejectedAndHistoryIsNotSilentlyDropped() async {
        let client = ContextScriptClient(); client.maliciousSummary = true
        do {
            _ = try await CoachContextEngine(client: client).prepare(history: history(100), userMessage: "继续", context: CoachContext(), memory: nil, thinking: false)
            XCTFail("不能保存伪造记忆")
        } catch { XCTAssertEqual(error as? CoachContextError, .memoryUnavailable) }
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testSummaryFailureDoesNotProceedWithUnrepresentedConstraints() async {
        let client = ContextScriptClient(); client.summaryError = LLMError.network("offline")
        do {
            _ = try await CoachAgent(client: client).reply(history: history(100), userMessage: "继续")
            XCTFail("不能漏掉旧限制后继续回答")
        } catch { XCTAssertEqual(error as? CoachContextError, .memoryUnavailable) }
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testOverflowRetriesOnceAndOtherErrorsNeverRetry() async throws {
        let client = ContextScriptClient(); client.failures = [overflow]
        _ = try await CoachAgent(client: client).reply(history: history(3), userMessage: "你好")
        XCTAssertEqual(client.requests.count, 2)
        let failing = ContextScriptClient(); failing.failures = [overflow, overflow]
        do { _ = try await CoachAgent(client: failing).reply(history: history(3), userMessage: "你好"); XCTFail() } catch {}
        XCTAssertEqual(failing.requests.count, 2)
        for error in [LLMError.http(status: 400, body: "invalid request"), .http(status: 401, body: "context_length_exceeded"),
                      .http(status: 429, body: "rate limit"), .network("timeout")] {
            let other = ContextScriptClient(); other.failures = [error]
            do { _ = try await CoachAgent(client: other).reply(history: [], userMessage: "你好"); XCTFail() } catch {}
            XCTAssertEqual(other.requests.count, 1)
        }
        XCTAssertTrue(LLMError.http(status: 400, body: "prompt is too long: 123 tokens").isContextOverflow)
    }

    func testStreamingNeverRetriesAfterTextReasoningOrToolOutput() async {
        for prefix in [[LLMStreamEvent.text("部分回复")], [.reasoning("思考")], [.toolCall(id: "1", name: "create_plan", argumentsJSON: "{}")]] {
            let client = ContextScriptClient(); client.streamPrefix = prefix; client.failures = [overflow]
            do {
                for try await _ in CoachAgent(client: client).streamReply(history: [], userMessage: "你好") {}
                XCTFail()
            } catch {}
            XCTAssertEqual(client.requests.count, 1)
        }
    }

    func testStreamingOverflowAndOutputTruncation() async throws {
        let client = ContextScriptClient(); client.failures = [overflow]
        var completions = 0
        for try await event in CoachAgent(client: client).streamReply(history: history(3), userMessage: "你好") {
            if case .completed = event { completions += 1 }
        }
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(client.requests.count, 2)
        for reason in ["length", "max_tokens"] {
            let limited = ContextScriptClient(); limited.stopReason = reason
            do {
                for try await event in CoachAgent(client: limited).streamReply(history: [], userMessage: "排计划") {
                    if case .completed = event { XCTFail("截断结果不能成为可执行计划") }
                }
                XCTFail()
            } catch { XCTAssertEqual(error as? CoachContextError, .truncated) }
            XCTAssertEqual(limited.requests.count, 1)
        }
    }

    func testCancellationStopsSummaryBeforeReply() async {
        let client = ContextScriptClient(); client.summaryDelay = 5_000_000_000
        let history = history(100)
        let task = Task { try await CoachAgent(client: client).reply(history: history, userMessage: "继续") }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testIncrementalMemoryKeepsCorrectionsAndCountsSummaryUsage() async throws {
        let client = ContextScriptClient(); client.omitFacts = true
        var usage = LLMUsage()
        let recording = UsageRecordingClient(base: client) { usage = usage + $0 }
        let engine = CoachContextEngine(client: recording)
        var turns = history(20)
        let first = try await engine.prepare(history: turns, userMessage: "今天", context: CoachContext(), memory: nil, thinking: false)
        let memory = try XCTUnwrap(first.memory)
        XCTAssertTrue(memory.text(history: turns).contains("膝盖旧伤"), "模型遗漏也不能丢失明确限制")
        let firstCalls = client.summaryRequests.count
        turns += [CoachTurn(role: .user, content: "限制：更正，每周改为三天训练。", id: UUID(), date: Date(timeIntervalSince1970: 100))]
        turns += history(30).enumerated().map { index, turn in
            var result = turn
            result.content = "普通训练回顾。" + String(repeating: "按进度记录。", count: 18)
            result.date = Date(timeIntervalSince1970: Double(101 + index))
            return result
        }
        let next = try await engine.prepare(history: turns, userMessage: "这周怎么练", context: CoachContext(), memory: memory, thinking: false)
        let updated = try XCTUnwrap(next.memory)
        XCTAssertGreaterThan(updated.coveredCount, memory.coveredCount)
        let quotes = updated.text(history: turns)
        XCTAssertTrue(quotes.contains("膝盖旧伤"))
        XCTAssertTrue(quotes.contains("每周改为三天"))
        let system = next.request.messages.first!.content
        XCTAssertTrue(system.contains("最新明确纠正"))
        for request in client.summaryRequests.dropFirst(firstCalls) {
            let source = request.messages.last!.content.components(separatedBy: "新资料：\n").last!
            XCTAssertFalse(source.contains(turns[0].id!.uuidString), "已覆盖原文不能再次作为新资料总结")
        }
        XCTAssertEqual(usage.totalTokens, client.summaryRequests.count * 15)
    }

    func testAnonymousHistoryHasStableCacheAndNoReductionDoesNotRetry() async throws {
        let client = ContextScriptClient()
        let turns = history(20).map { CoachTurn(role: $0.role, content: $0.content) }
        let engine = CoachContextEngine(client: client)
        let first = try await engine.prepare(history: turns, userMessage: "继续", context: CoachContext(), memory: nil, thinking: false)
        let count = client.summaryRequests.count
        _ = try await engine.prepare(history: turns, userMessage: "继续", context: CoachContext(), memory: first.memory, thinking: false)
        XCTAssertEqual(client.summaryRequests.count, count)
        let failing = ContextScriptClient(); failing.failures = [overflow]
        do { _ = try await CoachAgent(client: failing).reply(history: [], userMessage: "你好"); XCTFail() }
        catch { XCTAssertEqual(error as? CoachContextError, .tooLarge) }
        XCTAssertEqual(failing.requests.count, 1, "不能重发完全相同的超限请求")
    }

    func testFixedContextOverflowFailsBeforeAnyModelCall() async {
        let client = ContextScriptClient()
        var context = CoachContext()
        context.profileText = String(repeating: "profile details ", count: 2_000)
        do {
            _ = try await CoachAgent(client: client).reply(history: history(20), userMessage: "继续", context: context)
            XCTFail()
        } catch { XCTAssertEqual(error as? CoachContextError, .tooLarge) }
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertTrue(client.summaryRequests.isEmpty)
    }

    func testCachedHistoryIsReplannedForSmallerBudget() async throws {
        let client = ContextScriptClient(), turns = history(20)
        let first = try await CoachContextEngine(client: client).prepare(history: turns, userMessage: "继续", context: CoachContext(), memory: nil, thinking: false)
        var smaller = policy
        smaller.inputCap = 8_000
        let next = try await CoachContextEngine(client: client, policy: smaller).prepare(history: turns, userMessage: "继续", context: CoachContext(), memory: first.memory, thinking: false)
        try smaller.validate(next.request)
        XCTAssertGreaterThan(try XCTUnwrap(next.memory).coveredCount, try XCTUnwrap(first.memory).coveredCount)
        XCTAssertTrue(next.request.messages.map(\.content).joined().contains("膝盖旧伤"))
    }

    func testPlanningPrimitivesPerformanceAndMemory() {
        let turns = history(500)
        let request = LLMRequest(messages: turns.map { .user($0.content) })
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            _ = CoachMemory.digest(turns[...])
            _ = policy.tokens(request)
            _ = CoachContextEngine.rounds(turns)
        }
    }
}
