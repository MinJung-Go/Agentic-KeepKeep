import XCTest
@testable import AgenticKeepKeep

/// 拦下 URLSession 的请求，直接回放预设响应体。
/// 用来覆盖**真实的 wire 解码路径** —— 这一层过去完全没有测试，
/// 「思考内容拿不到」正是漏在这里（非流式响应体根本没解析 `reasoning_content`）。
final class MockURLProtocol: URLProtocol {

    /// 收到请求时的响应构造器：返回 (状态码, 响应体)
    static var responder: ((URLRequest) -> (Int, Data))?

    /// 最近一次被拦下的请求体，用于断言发出去的参数
    private(set) static var lastRequestBody: Data?

    static func reset() {
        responder = nil
        lastRequestBody = nil
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol 拿不到 httpBody，流式请求体在 httpBodyStream 里
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let size = 4_096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            Self.lastRequestBody = data
        } else {
            Self.lastRequestBody = request.httpBody
        }

        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let (status, body) = responder(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://mock.local")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 两个协议客户端的 wire 解码：思考内容、工具调用、流式分片
final class LLMWireTests: XCTestCase {

    private let config = LLMClientConfig(
        baseURL: "https://mock.local/v1",
        apiKey: "test-key",
        model: "test-model"
    )

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func reply(_ json: String, status: Int = 200) {
        MockURLProtocol.responder = { _ in (status, Data(json.utf8)) }
    }

    // MARK: - OpenAI 兼容：非流式

    func testOpenAICompleteDecodesReasoningContent() async throws {
        reply(#"""
        {
          "choices": [{
            "message": {
              "role": "assistant",
              "content": "建议减载。",
              "reasoning_content": "睡眠只有 6.2 小时，HRV 下行。"
            },
            "finish_reason": "stop"
          }],
          "usage": {"prompt_tokens": 900, "completion_tokens": 120, "total_tokens": 1020}
        }
        """#)

        let client = OpenAICompatibleClient(config: config, session: MockURLProtocol.makeSession())
        let response = try await client.complete(LLMRequest(messages: [.user("要不要减量")]))

        XCTAssertEqual(response.content, "建议减载。")
        XCTAssertEqual(response.reasoning, "睡眠只有 6.2 小时，HRV 下行。", "非流式响应体也要解析思考内容")
        XCTAssertEqual(response.usage.promptTokens, 900)
    }

    func testOpenAICompleteAcceptsReasoningAlias() async throws {
        // 有些端点用 `reasoning` 而不是 `reasoning_content`
        reply(#"""
        {"choices":[{"message":{"content":"ok","reasoning":"别名字段"},"finish_reason":"stop"}]}
        """#)

        let client = OpenAICompatibleClient(config: config, session: MockURLProtocol.makeSession())
        let response = try await client.complete(LLMRequest(messages: [.user("hi")]))

        XCTAssertEqual(response.reasoning, "别名字段")
    }

    func testOpenAICompleteWithoutReasoningStaysNil() async throws {
        reply(#"""
        {"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}
        """#)

        let client = OpenAICompatibleClient(config: config, session: MockURLProtocol.makeSession())
        let response = try await client.complete(LLMRequest(messages: [.user("hi")]))

        XCTAssertNil(response.reasoning, "不支持思考的模型不该被塞进空思考")
    }

    // MARK: - OpenAI 兼容：流式

    func testOpenAIStreamDecodesReasoningFrames() async throws {
        let sse = """
        data: {"choices":[{"delta":{"reasoning_content":"先看恢复。"},"finish_reason":null}]}

        data: {"choices":[{"delta":{"reasoning_content":"再看训练量。"},"finish_reason":null}]}

        data: {"choices":[{"delta":{"content":"建议减载。"},"finish_reason":null}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
        reply(sse)

        let client = OpenAICompatibleClient(config: config, session: MockURLProtocol.makeSession())
        var events: [LLMStreamEvent] = []
        for try await event in client.stream(LLMRequest(messages: [.user("hi")])) {
            events.append(event)
        }

        let reasoning = events.compactMap { event -> String? in
            if case .reasoning(let chunk) = event { return chunk }
            return nil
        }
        XCTAssertEqual(reasoning, ["先看恢复。", "再看训练量。"])

        let text = events.compactMap { event -> String? in
            if case .text(let chunk) = event { return chunk }
            return nil
        }
        XCTAssertEqual(text, ["建议减载。"])
        XCTAssertTrue(events.contains(.finished(reason: "stop")))
    }

    func testOpenAIStreamStitchesToolCallFragments() async throws {
        // 工具参数是分片到达的，最容易拼错
        let sse = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"create_plan","arguments":"{\\"title\\":"}}]},"finish_reason":null}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"4 周计划\\"}"}}]},"finish_reason":null}]}

        data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

        """
        reply(sse)

        let client = OpenAICompatibleClient(config: config, session: MockURLProtocol.makeSession())
        var calls: [LLMToolCall] = []
        for try await event in client.stream(LLMRequest(messages: [.user("hi")])) {
            if case .toolCall(let id, let name, let json) = event {
                calls.append(LLMToolCall(id: id, name: name, argumentsJSON: json))
            }
        }

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "create_plan")
        XCTAssertEqual(calls.first?.argumentsJSON, #"{"title":"4 周计划"}"#)
    }

    func testOpenAIStreamSurfacesHTTPError() async {
        reply(#"{"error":{"message":"invalid api key"}}"#, status: 401)

        let client = OpenAICompatibleClient(config: config, session: MockURLProtocol.makeSession())

        do {
            for try await _ in client.stream(LLMRequest(messages: [.user("hi")])) {}
            XCTFail("401 应当抛错")
        } catch let error as LLMError {
            guard case .http(let status, _) = error else {
                return XCTFail("错误类型不符：\(error)")
            }
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    // MARK: - 请求体

    func testThinkingFlagEncodedInRequestBody() async throws {
        reply(#"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#)

        let client = OpenAICompatibleClient(config: config, session: MockURLProtocol.makeSession())
        _ = try await client.complete(LLMRequest(messages: [.user("hi")], thinkingEnabled: true))

        let body = try XCTUnwrap(MockURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let thinking = try XCTUnwrap(json["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "enabled")
    }

    func testThinkingParamOmittedWhenDisabled() async throws {
        reply(#"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#)

        let client = OpenAICompatibleClient(config: config, session: MockURLProtocol.makeSession())
        _ = try await client.complete(LLMRequest(messages: [.user("hi")], thinkingEnabled: nil))

        let body = try XCTUnwrap(MockURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["thinking"], "关闭时不应该发 thinking 参数，否则不支持的模型会 400")
    }

    // MARK: - Anthropic

    func testAnthropicCompleteDecodesThinkingBlock() async throws {
        reply(#"""
        {
          "content": [
            {"type": "thinking", "thinking": "先算恢复缺口。"},
            {"type": "text", "text": "这周减载 20%。"}
          ],
          "usage": {"input_tokens": 800, "output_tokens": 90}
        }
        """#)

        var anthropicConfig = config
        anthropicConfig.baseURL = "https://mock.local"
        let client = AnthropicClient(config: anthropicConfig, session: MockURLProtocol.makeSession())
        let response = try await client.complete(LLMRequest(messages: [.user("hi")], thinkingEnabled: true))

        XCTAssertEqual(response.content, "这周减载 20%。")
        XCTAssertEqual(response.reasoning, "先算恢复缺口。", "thinking 块要解析到 reasoning")
        XCTAssertEqual(response.usage.promptTokens, 800)
    }

    func testAnthropicStreamDecodesThinkingDelta() async throws {
        let sse = """
        data: {"type":"message_start","message":{"usage":{"input_tokens":700,"output_tokens":0}}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"恢复不足，"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"建议减载。"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"先减 20%。"}}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":110}}

        """
        reply(sse)

        var anthropicConfig = config
        anthropicConfig.baseURL = "https://mock.local"
        let client = AnthropicClient(config: anthropicConfig, session: MockURLProtocol.makeSession())

        var events: [LLMStreamEvent] = []
        for try await event in client.stream(LLMRequest(messages: [.user("hi")])) {
            events.append(event)
        }

        let reasoning = events.compactMap { event -> String? in
            if case .reasoning(let chunk) = event { return chunk }
            return nil
        }
        XCTAssertEqual(reasoning, ["恢复不足，", "建议减载。"])

        let text = events.compactMap { event -> String? in
            if case .text(let chunk) = event { return chunk }
            return nil
        }
        XCTAssertEqual(text, ["先减 20%。"])

        // 输入侧与输出侧用量分两次上报，合并后两边都要在
        let usage = events.compactMap { event -> LLMUsage? in
            if case .usage(let value) = event { return value }
            return nil
        }.last
        XCTAssertEqual(usage?.promptTokens, 700)
        XCTAssertEqual(usage?.completionTokens, 110)
    }
}
