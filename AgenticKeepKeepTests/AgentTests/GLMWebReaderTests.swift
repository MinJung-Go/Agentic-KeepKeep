import XCTest
@testable import AgenticKeepKeep

@MainActor
final class GLMWebReaderTests: XCTestCase {
    private let source = URL(string: "https://example.org/study")!
    private var config: LLMClientConfig {
        LLMClientConfig(baseURL: "https://open.bigmodel.cn/api/paas/v4", apiKey: "fixture", model: "glm-5.3-flash")
    }

    func testToolArgumentsRejectUnrepresentableAndFractionalIndices() async throws {
        for number in ["1e200", "1.5", "\"not a number\""] {
            let reader = Data("{\"source_index\":\(number)}".utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(WebReaderArguments.self, from: reader))
            let search = Data("{\"topic\":\"sleep\",\"count\":\(number)}".utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(FitnessSearchArguments.self, from: search))
        }
        XCTAssertNil(try JSONDecoder().decode(FitnessSearchArguments.self, from: Data(#"{"topic":"sleep"}"#.utf8)).count)
    }

    func testReaderRequestUsesTextAndOmitsImagesAndConversation() async throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: GLMWebReader.requestBody(url: source)) as? [String: Any])
        XCTAssertEqual(body["url"] as? String, source.absoluteString)
        XCTAssertEqual(body["return_format"] as? String, "text")
        XCTAssertEqual(body["retain_images"] as? Bool, false)
        XCTAssertNil(body["messages"])
        for value in ["http://example.org", "https://localhost/a", "https://127.0.0.1", "https://[::1]", "https://192.168.1.1", "https://a.local", "https://user:pass@example.org", "file:///tmp/a", "https://example.org:8080"] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertThrowsError(try GLMWebReader.requestBody(url: url), value)
        }
    }

    func testReaderKeepsSelectedSourceAndBoundsLargeContent() async throws {
        let data = try JSONSerialization.data(withJSONObject: ["reader_result": [
            "title": "研究", "content": String(repeating: "正文", count: 20_000), "url": "https://untrusted.example/changed"
        ]])
        let result = try GLMWebReader.decode(data, source: source)
        XCTAssertFalse(result.failed)
        XCTAssertEqual(result.sources, [source])
        XCTAssertTrue(result.content.contains("结果过长"))
        XCTAssertTrue(result.content.contains("不可信引用"))
        XCTAssertFalse(result.content.contains("untrusted.example"))
        XCTAssertLessThanOrEqual(result.content.utf8.count, GLMWebReader.toolResultByteLimit)
    }

    func testMissingBodyIsFailureEvenIfDescriptionExists() async throws {
        for fixture in [#"{}"#, #"{"reader_result":{"description":"summary"}}"#, #"{"reader_result":{"content":"  "}}"#] {
            let result = try GLMWebReader.decode(Data(fixture.utf8), source: source)
            XCTAssertTrue(result.failed)
            XCTAssertTrue(result.sources.isEmpty)
        }
        XCTAssertThrowsError(try GLMWebReader.decode(Data("invalid".utf8), source: source))
    }

    func testReaderTransportAndHTTPFailure() async throws {
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in (200, Data(#"{"reader_result":{"title":"研究","content":"网页正文"}}"#.utf8)) }
        let reader = GLMWebReader(config: config, session: MockURLProtocol.makeSession())
        let result = try await reader.read(url: source)
        XCTAssertTrue(result.content.contains("网页正文"))
        let body = try XCTUnwrap(MockURLProtocol.lastRequestBody)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("return_format"))
        MockURLProtocol.responder = { _ in (403, Data()) }
        let failure = try await reader.read(url: source)
        XCTAssertTrue(failure.failed)
        XCTAssertTrue(failure.sources.isEmpty)
    }

    func testLocalQueryThenSearchThenReadHasTimeToAnswer() async throws {
        let calls = [
            LLMToolCall(id: "local", name: CoachTools.records.name, argumentsJSON: #"{"kind":"health"}"#),
            LLMToolCall(id: "search", name: CoachTools.search.name, argumentsJSON: #"{"topic":"sleep","count":50}"#),
            LLMToolCall(id: "read", name: CoachTools.reader.name, argumentsJSON: #"{"source_index":50}"#)
        ]
        let client = MockLLMClient(responses: calls.map { .calls([$0]) } + [.text("根据资料回答")])
        var executed: [String] = []
        var events: [CoachToolActivity] = []
        let items = (1...50).map { ["title": "研究", "link": "https://example.org/\($0)", "content": String(repeating: "摘要", count: 100)] }
        let search = try GLMWebSearch.decode(JSONSerialization.data(withJSONObject: ["search_result": items]), count: 50)
        let tools = CoachTools(webSearchEnabled: true, onActivity: { events.append($0) }) { call in
            executed.append(call.name)
            return call.name == CoachTools.search.name ? search : CoachToolResult(content: "查询内容")
        }
        _ = try await CoachAgent(client: client, policy: CoachContextPolicy(window: 131_072, inputCap: 131_072), tools: tools).reply(history: [], userMessage: "查询并阅读")
        XCTAssertEqual(executed, calls.map(\.name))
        XCTAssertTrue(client.requests[2].messages.contains { $0.role == .tool && $0.content.contains("https://example.org/50") })
        XCTAssertEqual(events.last?.title, "阅读公开网页")
        XCTAssertEqual(events.last?.status, .completed)
        XCTAssertFalse(client.requests[3].tools.contains { $0.name == CoachTools.reader.name })
    }

    func testReaderLimitedToTwoCallsAndDisabledWithSearch() async throws {
        let read = LLMToolCall(id: "r", name: CoachTools.reader.name, argumentsJSON: #"{"source_index":1}"#)
        let client = MockLLMClient(responses: [.calls([read]), .calls([read]), .calls([read]), .text("结束")])
        var count = 0
        let tools = CoachTools(webSearchEnabled: true) { _ in count += 1; return CoachToolResult(content: "正文") }
        _ = try await CoachAgent(client: client, tools: tools).reply(history: [], userMessage: "阅读")
        XCTAssertEqual(count, 2)
        XCTAssertTrue(client.requests.last!.messages.contains { $0.content.contains("2页上限") })
        let disabled = MockLLMClient(responses: [.calls([read]), .text("未开启")])
        let off = CoachTools { _ in XCTFail("Reader should not execute"); return CoachToolResult(content: "") }
        _ = try await CoachAgent(client: disabled, tools: off).reply(history: [], userMessage: "阅读")
        XCTAssertFalse(disabled.requests[0].tools.contains { $0.name == CoachTools.reader.name })
    }
}
