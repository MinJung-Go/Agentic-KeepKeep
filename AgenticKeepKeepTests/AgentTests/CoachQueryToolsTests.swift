import XCTest
@testable import AgenticKeepKeep

@MainActor
final class CoachQueryToolsTests: XCTestCase {
    private func call(_ id: String = "q1", name: String = "query_local_records") -> LLMToolCall {
        LLMToolCall(id: id, name: name,
                    argumentsJSON: #"{"kind":"health","start_date":"2026-09-14","end_date":"2026-09-14"}"#)
    }

    func testLocalResultFeedsFollowUpButIsNotReturnedAsHistory() async throws {
        let client = MockLLMClient(responses: [.calls([call()]), .text("今天走了 3456 步。")])
        var count = 0
        let tools = CoachTools { _ in
            count += 1
            return CoachToolResult(content: "LOCAL_AGGREGATE_MARKER: 今天 3456 步，09:00同步。")
        }
        let reply = try await CoachAgent(client: client, tools: tools).reply(history: [], userMessage: "今天走了多少步")
        XCTAssertEqual(count, 1)
        XCTAssertEqual(client.requests.count, 2)
        let result = try XCTUnwrap(client.requests.last?.messages.first { $0.role == .tool })
        XCTAssertEqual(result.toolCallId, "q1")
        XCTAssertTrue(result.content.contains("3456"))
        XCTAssertFalse(reply.text?.contains("LOCAL_AGGREGATE_MARKER") ?? true)
        XCTAssertFalse(client.requests[0].messages.map(\.content).joined().contains("近 28 天"))
        client.enqueue(.text("你好"))
        _ = try await CoachAgent(client: client, tools: tools).reply(
            history: [CoachTurn(role: .user, content: "今天走了多少步"),
                      CoachTurn(role: .assistant, content: reply.text ?? "")], userMessage: "你好")
        XCTAssertFalse(client.requests.last!.messages.contains { $0.role == .tool })
    }

    func testToolLoopHasTwoBatchesAndKeepsPlanTools() async throws {
        let client = MockLLMClient(responses: [.calls([call()]), .calls([call("q2")]), .calls([call("q3")])])
        var count = 0
        let tools = CoachTools { _ in count += 1; return CoachToolResult(content: "没有可用值") }
        let reply = try await CoachAgent(client: client, tools: tools).reply(history: [], userMessage: "查询")
        XCTAssertEqual(count, 2)
        XCTAssertEqual(client.requests.count, 3)
        XCTAssertTrue(reply.text?.contains("查询已达上限") == true)
        XCTAssertFalse(client.requests[2].tools.contains { $0.name == CoachTools.records.name })
        XCTAssertTrue(client.requests[2].tools.contains { $0.name == CoachAgent.createPlanTool.name })
    }

    func testDisabledSearchNeverExecutesEvenIfModelInventsCall() async throws {
        let client = MockLLMClient(responses: [.calls([call(name: "search_public_fitness")]), .text("联网未开启")])
        var count = 0
        let tools = CoachTools { _ in count += 1; return CoachToolResult(content: "unexpected") }
        _ = try await CoachAgent(client: client, tools: tools).reply(history: [], userMessage: "搜索")
        XCTAssertEqual(count, 0)
        XCTAssertFalse(client.requests[0].tools.contains { $0.name == CoachTools.search.name })
    }

    func testSearchRunsOnlyOnceAndShowsReturnedSource() async throws {
        let search = LLMToolCall(id: "s1", name: CoachTools.search.name, argumentsJSON: #"{"topic":"sleep"}"#)
        let client = MockLLMClient(responses: [.calls([search]), .calls([search]), .text("参考睡眠指南。")])
        var count = 0
        let tools = CoachTools(webSearchEnabled: true) { _ in
            count += 1
            return CoachToolResult(content: "公共研究摘要", sources: [URL(string: "https://example.org/study")!])
        }
        let reply = try await CoachAgent(client: client, tools: tools).reply(history: [], userMessage: "搜索睡眠指南")
        XCTAssertEqual(count, 1)
        XCTAssertTrue(reply.text?.contains("[来源 1](https://example.org/study)") == true)
        XCTAssertTrue(client.requests[2].messages.contains { $0.content.contains("联网搜索已达上限") })
    }

    func testQueryFailureIsDataFailureNotAnEmptyDatabase() async throws {
        let client = MockLLMClient(responses: [.calls([call()]), .text("暂时查询失败")])
        let tools = CoachTools { _ in throw LLMError.network("offline") }
        _ = try await CoachAgent(client: client, tools: tools).reply(history: [], userMessage: "查询")
        XCTAssertTrue(client.requests[1].messages.contains { $0.content.contains("不能视为没有记录") })
    }

    func testCancellationDoesNotIssueFollowUp() async {
        let client = MockLLMClient(responses: [.calls([call()])])
        let tools = CoachTools { _ in throw CancellationError() }
        do {
            _ = try await CoachAgent(client: client, tools: tools).reply(history: [], userMessage: "查询")
            XCTFail("Should cancel")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(client.requests.count, 1)
    }

    func testOversizedToolDataIsBoundedWithoutLosingUserRestriction() async throws {
        let client = MockLLMClient(responses: [.calls([call()]), .text("请缩小范围")])
        let tools = CoachTools { _ in CoachToolResult(content: String(repeating: "大型结果", count: 10_000)) }
        _ = try await CoachAgent(client: client, tools: tools).reply(
            history: [CoachTurn(role: .user, content: "膝盖受伤，避免跳跃")], userMessage: "查询")
        let followUp = client.requests[1]
        try CoachContextPolicy().validate(followUp)
        XCTAssertTrue(followUp.messages.contains { $0.content.contains("膝盖受伤") })
        let result = try XCTUnwrap(followUp.messages.first { $0.role == .tool })
        XCTAssertLessThanOrEqual(result.content.utf8.count, 1800)
        XCTAssertTrue(result.content.contains("结果过长"))
    }

    func testFollowUpOverflowDoesNotReplaySearch() async {
        let client = MockLLMClient(responses: [.calls([call()])])
        client.enqueue(error: LLMError.http(status: 400, body: "context_length_exceeded"))
        var count = 0
        let tools = CoachTools { _ in count += 1; return CoachToolResult(content: "结果") }
        do {
            _ = try await CoachAgent(client: client, tools: tools).reply(history: [], userMessage: "查询")
            XCTFail()
        } catch { XCTAssertEqual(error as? CoachContextError, .tooLarge) }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(client.requests.count, 2)
    }
    func testQueryThenPlanStillReturnsConfirmableDraft() async throws {
        let plan = LLMToolCall(id: "plan", name: "create_plan", argumentsJSON:
            #"{"title":"轻量训练","goal":"general","weeks":1,"days":[{"dayOffset":0,"title":"全身","exercises":[{"name":"深蹲"}]}]}"#)
        let client = MockLLMClient(responses: [.calls([call()]), .calls([plan])])
        let tools = CoachTools { _ in CoachToolResult(content: "今天恢复数据可用") }
        let reply = try await CoachAgent(client: client, tools: tools).reply(history: [], userMessage: "按恢复情况排计划")
        XCTAssertEqual(reply.planDraft?.title, "轻量训练")
        XCTAssertNotNil(reply.planArgumentsJSON)
    }

    func testStreamingReturnsFinalTextAndDoesNotExposeToolPayload() async throws {
        let client = MockLLMClient(responses: [.calls([call()]), .text("今天走了1234步")])
        let tools = CoachTools { _ in CoachToolResult(content: "HIDDEN_TOOL_RESULT 1234") }
        var visible = ""
        var completed: CoachReply?
        for try await event in CoachAgent(client: client, tools: tools).streamReply(history: [], userMessage: "今天步数") {
            switch event {
            case .text(let value): visible += value
            case .completed(let value): completed = value
            case .reasoning: break
            }
        }
        XCTAssertTrue(visible.contains("1234"))
        XCTAssertFalse(visible.contains("HIDDEN_TOOL_RESULT"))
        XCTAssertEqual(completed?.text, visible)
    }

    func testEmptyFinalResponseDoesNotBecomeBlankChatBubble() async {
        let client = MockLLMClient(responses: [.calls([call()]), .text("")])
        let tools = CoachTools { _ in CoachToolResult(content: "数据") }
        do {
            _ = try await CoachAgent(client: client, tools: tools).reply(history: [], userMessage: "查询")
            XCTFail()
        } catch { XCTAssertEqual(error as? AgentError, .emptyResponse) }
    }

    func testCurrentPlanAndAllQuerySchemasFitDefaultBudget() async throws {
        let client = MockLLMClient(responses: [.text("已了解")])
        let tools = CoachTools(webSearchEnabled: true) { _ in CoachToolResult(content: "数据") }
        var context = CoachContext()
        context.planState = String(repeating: "计划", count: 330)
        _ = try await CoachAgent(client: client, tools: tools).reply(history: [], userMessage: "今天怎么练", context: context)
        try CoachContextPolicy().validate(client.requests[0])
    }

    func testDeletePlanDraftRetainsIdentityAndRevision() async throws {
        let mutation = LLMToolCall(id: "edit", name: "propose_plan_adjustment", argumentsJSON:
            #"{"planID":"00000000-0000-0000-0000-000000000001","revision":"version","summary":"删除旧计划","changes":[{"action":"delete_plan","detail":"用户要求"}]}"#)
        let client = MockLLMClient(responses: [.calls([mutation])])
        let tools = CoachTools { _ in XCTFail("Mutation must wait for confirmation"); return CoachToolResult(content: "") }
        let reply = try await CoachAgent(client: client, tools: tools).reply(history: [], userMessage: "删除旧计划")
        XCTAssertEqual(reply.adjustmentDraft?.planID, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(reply.adjustmentDraft?.revision, "version")
        XCTAssertEqual(reply.adjustmentDraft?.changes.first?.action, "delete_plan")
    }

    func testMalformedMutationBatchCannotPartiallyDecode() async {
        let json = #"{"planID":"id","revision":"v","summary":"调整","changes":[{"action":"skip","detail":"跳过"},{"action":"replace","exercises":"invalid"}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(PlanAdjustmentDraft.self, from: Data(json.utf8)))
    }

    func testToolFollowUpPreservesThinkingButNotOpaqueBlocksInVisibleReply() async throws {
        let block = JSONValue.object(["type": .string("thinking"), "thinking": .string("先查询"), "signature": .string("opaque-signature")])
        let client = MockLLMClient()
        client.streamEvents = [.reasoning("先查询"), .continuationBlocks([block]),
                               .toolCall(id: "q", name: CoachTools.records.name, argumentsJSON: "{}"), .finished(reason: "tool_calls")]
        let tools = CoachTools { _ in CoachToolResult(content: "已查询") }
        let result = try await CoachAgent(client: client, tools: tools).reply(history: [], userMessage: "查数据")
        let assistant = try XCTUnwrap(client.streamRequests[1].messages.first { !$0.toolCalls.isEmpty })
        XCTAssertEqual(assistant.reasoning, "先查询")
        XCTAssertEqual(assistant.thinkingBlocks, [block])
        XCTAssertFalse(result.text?.contains("opaque-signature") == true)
    }

}
