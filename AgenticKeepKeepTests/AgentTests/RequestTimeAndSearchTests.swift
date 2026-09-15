import XCTest
@testable import AgenticKeepKeep

final class RequestTimeAndSearchTests: XCTestCase {
    func testRuntimeTimeUsesLocalDayAndDoesNotMutateStoredMessages() throws {
        let request = LLMRequest(messages: [.system("规则"), .user("今天")])
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-14T18:00:00Z"))
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let first = request.runtimeMessages(now: date, timeZone: zone)
        XCTAssertTrue(first[0].content.contains("2026-09-15T02:00:00+08:00"))
        XCTAssertTrue(first[0].content.contains("Tuesday"))
        XCTAssertTrue(first[0].content.contains("Asia/Shanghai"))
        XCTAssertEqual(request.messages[0].content, "规则")
        XCTAssertNotEqual(first, request.runtimeMessages(now: date.addingTimeInterval(86400), timeZone: zone))
        XCTAssertEqual(first.filter { $0.role == .user }.map(\.content), ["今天"])
    }

    func testOfficialSearchEndpointValidation() {
        XCTAssertTrue(GLMWebSearch.isOfficialEndpoint("https://open.bigmodel.cn/api/paas/v4/"))
        for url in ["http://open.bigmodel.cn/api/paas/v4", "https://open.bigmodel.cn.evil.test/api/paas/v4",
                    "https://example.org/v1", "https://secret@open.bigmodel.cn/api/paas/v4",
                    "https://open.bigmodel.cn/api/coding/paas/v4", "https://open.bigmodel.cn/api/paas/v4?redirect=1"] {
            XCTAssertFalse(GLMWebSearch.isOfficialEndpoint(url))
        }
    }

    func testSearchBodyOnlyContainsPublicTopic() throws {
        for topic in FitnessSearchTopic.allCases {
            let body = try JSONSerialization.jsonObject(with: GLMWebSearch.requestBody(topic: topic)) as! [String: Any]
            XCTAssertEqual(body["search_query"] as? String, topic.query)
            XCTAssertNil(body["messages"])
            XCTAssertNil(body["user_id"])
            XCTAssertEqual(body["count"] as? Int, 10)
        }
        XCTAssertNil(FitnessSearchTopic(rawValue: "我的体重80kg"))
    }

    func testSearchResponseLimitsResultsAndRejectsUnsafeLinks() throws {
        let items: [[String: String]] = [
            ["link": "javascript:alert(1)", "content": "untrusted"],
            ["link": "https://user:secret@example.org/private", "content": "untrusted"]
        ] + (0..<60).map { ["title": "研究", "link": "https://example.org/\($0)", "content": String(repeating: "摘要", count: 1000)] }
        let result = try GLMWebSearch.decode(JSONSerialization.data(withJSONObject: ["search_result": items]))
        XCTAssertEqual(result.sources.count, 10)
        XCTAssertFalse(result.content.contains("javascript"))
        XCTAssertFalse(result.content.contains("secret"))
        XCTAssertLessThan(result.content.utf8.count, 8000)
        let empty = try GLMWebSearch.decode(Data(#"{"search_result":[]}"#.utf8))
        XCTAssertTrue(empty.sources.isEmpty)
        XCTAssertTrue(empty.content.contains("没有返回可用来源"))
    }

    func testSearchCountBoundsAndFiftyResultsSurviveToolLimit() throws {
        for (requested, expected) in [(Int.min, 1), (1, 1), (10, 10), (50, 50), (Int.max, 50)] {
            let data = try GLMWebSearch.requestBody(topic: .recovery, count: requested)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["count"] as? Int, expected)
        }
        let items = (0..<60).map { ["title": "研究", "content": String(repeating: "摘要", count: 1000), "link": "https://example.org/\($0)"] }
        let data = try JSONSerialization.data(withJSONObject: ["search_result": items])
        let result = try GLMWebSearch.decode(data, count: 50)
        XCTAssertEqual(result.sources.count, 50)
        XCTAssertTrue(result.content.contains("https://example.org/49"))
        XCTAssertFalse(result.content.contains("https://example.org/50"))
        XCTAssertEqual(CoachToolClient.bounded(result.content, bytes: GLMWebSearch.toolResultByteLimit), result.content)
        XCTAssertEqual(try GLMWebSearch.decode(data, count: 1).sources.count, 1)
    }

    func testSearchSettingDefaultsOnAndPreservesExplicitOptOut() {
        let name = "search.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = LLMSettings(defaults: defaults)
        XCTAssertTrue(first.webSearchEnabled)
        first.webSearchEnabled = false
        XCTAssertFalse(LLMSettings(defaults: defaults).webSearchEnabled)
        first.selectPreset(.openAI)
        XCTAssertFalse(first.supportsWebSearch)
    }

    func testBothTransportsInjectTime() async throws {
        defer { MockURLProtocol.reset() }
        let config = LLMClientConfig(baseURL: "https://fixture.invalid", apiKey: "fixture", model: "fixture")
        MockURLProtocol.responder = { _ in (200, Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8)) }
        _ = try await OpenAICompatibleClient(config: config, session: MockURLProtocol.makeSession()).complete(LLMRequest(messages: [.user("hi")]))
        let openAI = try XCTUnwrap(MockURLProtocol.lastRequestBody)
        XCTAssertTrue(String(decoding: openAI, as: UTF8.self).contains("请求时间"))
        MockURLProtocol.responder = { _ in (200, Data(#"{"content":[{"type":"text","text":"ok"}]}"#.utf8)) }
        _ = try await AnthropicClient(config: config, session: MockURLProtocol.makeSession()).complete(LLMRequest(messages: [.user("hi")]))
        let anthropic = try XCTUnwrap(MockURLProtocol.lastRequestBody)
        XCTAssertTrue(String(decoding: anthropic, as: UTF8.self).contains("请求时间"))
    }
    func testThinkingContinuationIsEncodedForBothProviders() async throws {
        defer { MockURLProtocol.reset() }
        let config = LLMClientConfig(baseURL: "https://fixture.invalid", apiKey: "fixture", model: "fixture")
        var message = LLMMessage.assistant("", toolCalls: [LLMToolCall(id: "q", name: "query", argumentsJSON: "{}")])
        message.reasoning = "先查询数据"
        message.thinkingBlocks = [.object(["type": .string("thinking"), "thinking": .string("先查询数据"), "signature": .string("signed-value")])]
        let request = LLMRequest(messages: [.user("查询"), message, .tool(callId: "q", content: "结果")])
        MockURLProtocol.responder = { _ in (200, Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8)) }
        _ = try await OpenAICompatibleClient(config: config, session: MockURLProtocol.makeSession()).complete(request)
        let openAI = try JSONSerialization.jsonObject(with: XCTUnwrap(MockURLProtocol.lastRequestBody)) as! [String: Any]
        let outgoing = (openAI["messages"] as! [[String: Any]]).first { $0["role"] as? String == "assistant" }!
        XCTAssertEqual(outgoing["reasoning_content"] as? String, "先查询数据")
        MockURLProtocol.responder = { _ in (200, Data(#"{"content":[{"type":"text","text":"ok"}]}"#.utf8)) }
        _ = try await AnthropicClient(config: config, session: MockURLProtocol.makeSession()).complete(request)
        let anthropic = try JSONSerialization.jsonObject(with: XCTUnwrap(MockURLProtocol.lastRequestBody)) as! [String: Any]
        let blocks = (anthropic["messages"] as! [[String: Any]]).first { $0["role"] as? String == "assistant" }!["content"] as! [[String: Any]]
        XCTAssertEqual(blocks.first?["signature"] as? String, "signed-value")
        XCTAssertEqual(blocks.last?["type"] as? String, "tool_use")
    }

    func testAnthropicStreamPreservesSignatureDeltasAndRedactedBlocks() async throws {
        defer { MockURLProtocol.reset() }
        let frames = [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"先查"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"nature"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"opaque"}}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"q","name":"query"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#
        ]
        MockURLProtocol.responder = { _ in (200, Data(frames.map { "data: " + $0 + "\n\n" }.joined().utf8)) }
        let config = LLMClientConfig(baseURL: "https://fixture.invalid", apiKey: "fixture", model: "fixture")
        let outcome = try await LLMStreamCollector.collect(AnthropicClient(config: config, session: MockURLProtocol.makeSession()).stream(LLMRequest(messages: [.user("查询")])))
        XCTAssertEqual(outcome.thinkingBlocks.count, 2)
        XCTAssertEqual(outcome.thinkingBlocks[0].objectValue?["signature"]?.stringValue, "signature")
        XCTAssertEqual(outcome.thinkingBlocks[1].objectValue?["data"]?.stringValue, "opaque")
        XCTAssertFalse(outcome.reasoning.contains("opaque"))
    }

}
