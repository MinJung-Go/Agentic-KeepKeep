import Foundation

/// Anthropic（Claude）原生协议的客户端。
/// 与 OpenAI 协议的差异：system 独立字段、content 为 block 数组、tools 用 input_schema、max_tokens 必填。
struct AnthropicClient: LLMClient {
    let config: LLMClientConfig
    private let session: URLSession
    private let apiVersion = "2023-06-01"

    init(config: LLMClientConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        guard !config.apiKey.isEmpty else { throw LLMError.missingAPIKey }
        guard let url = llmEndpointURL(base: config.baseURL, path: "/v1/messages") else {
            throw LLMError.invalidEndpoint(config.baseURL)
        }

        let body = try JSONEncoder().encode(WireRequest(request: request, defaultModel: config.model))
        let data = try await LLMHTTP.post(url: url, body: body, headers: headers, config: config, session: session,
                                          refreshBody: { try JSONEncoder().encode(WireRequest(request: request, defaultModel: config.model)) })

        let decoded: WireResponse
        do {
            decoded = try JSONDecoder().decode(WireResponse.self, from: data)
        } catch {
            throw LLMError.decoding(error.localizedDescription)
        }

        var text: String?
        var reasoning: String?
        var calls: [LLMToolCall] = []
        for block in decoded.content ?? [] {
            switch block.type {
            case "text":
                if let value = block.text {
                    text = (text ?? "") + value
                }
            case "thinking":
                // 开启了 thinking 时，思考内容与正文是并列的 block
                if let value = block.thinking {
                    reasoning = (reasoning ?? "") + value
                }
            case "tool_use":
                if let name = block.name {
                    let arguments = block.input.map(WireJSONString.init)?.value ?? "{}"
                    calls.append(LLMToolCall(id: block.id ?? UUID().uuidString, name: name, argumentsJSON: arguments))
                }
            default:
                break
            }
        }

        guard text != nil || !calls.isEmpty else { throw LLMError.emptyResponse }

        return LLMResponse(
            content: text,
            finishReason: decoded.stop_reason,
            toolCalls: calls,
            usage: decoded.usage?.domain ?? LLMUsage(),
            reasoning: reasoning,
            thinkingBlocks: (decoded.content ?? []).compactMap(\.continuationBlock)
        )
    }

    private var headers: [String: String] {
        [
            "x-api-key": config.apiKey,
            "anthropic-version": apiVersion
        ]
    }

    // MARK: - 流式

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !config.apiKey.isEmpty else { throw LLMError.missingAPIKey }
                    guard let url = llmEndpointURL(base: config.baseURL, path: "/v1/messages") else {
                        throw LLMError.invalidEndpoint(config.baseURL)
                    }

                    let body = try JSONEncoder().encode(WireRequest(request: request, defaultModel: config.model, streaming: true))

                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.timeoutInterval = config.timeout
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    for (key, value) in headers {
                        urlRequest.setValue(value, forHTTPHeaderField: key)
                    }
                    urlRequest.httpBody = body

                    let (bytes, response) = try await session.bytes(for: urlRequest)

                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.network("响应格式异常")
                    }

                    guard (200...299).contains(http.statusCode) else {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 4_096 { break }
                        }
                        throw LLMError.http(status: http.statusCode, body: llmShortBody(data))
                    }

                    var accumulator = LLMStreamAccumulator()
                    let decoder = JSONDecoder()
                    var preserved = AnthropicThinkingBlocks()

                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty else { continue }

                        guard let data = payload.data(using: .utf8),
                              let event = try? decoder.decode(WireStreamEvent.self, from: data) else {
                            continue
                        }

                        preserved.consume(event)
                        for streamEvent in accumulator.consume(event) {
                            continuation.yield(streamEvent)
                        }
                    }

                    if !preserved.blocks.isEmpty { continuation.yield(.continuationBlocks(preserved.blocks)) }
                    for streamEvent in accumulator.finish() {
                        continuation.yield(streamEvent)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMError.cancelled)
                } catch let error as LLMError {
                    continuation.finish(throwing: error)
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: LLMError.cancelled)
                } catch {
                    continuation.finish(throwing: LLMError.network(error.localizedDescription))
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Anthropic 的 SSE 事件
private struct WireStreamEvent: Decodable {
    struct Delta: Decodable {
        let type: String?
        let text: String?
        let thinking: String?
        let signature: String?
        let partial_json: String?
        let stop_reason: String?
    }

    struct ContentBlock: Decodable {
        let type: String?
        let id: String?
        let name: String?
        let thinking: String?
        let signature: String?
        let data: String?
    }

    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
    }

    struct Message: Decodable {
        let usage: Usage?
    }

    let type: String
    let index: Int?
    let delta: Delta?
    let content_block: ContentBlock?
    let usage: Usage?
    let message: Message?
}

extension LLMStreamAccumulator {

    /// 把 Anthropic 的流式事件归一化后交给累积器
    fileprivate mutating func consume(_ event: WireStreamEvent) -> [LLMStreamEvent] {
        switch event.type {
        case "message_start":
            if let input = event.message?.usage?.input_tokens {
                setUsage(LLMUsage(promptTokens: input, completionTokens: 0, totalTokens: input))
            }
            return []

        case "content_block_start":
            guard let block = event.content_block, block.type == "tool_use" else { return [] }
            return consume(Delta(
                toolCallIndex: event.index ?? 0,
                toolCallID: block.id,
                toolCallName: block.name,
                toolCallArguments: ""
            ))

        case "content_block_delta":
            guard let delta = event.delta else { return [] }
            switch delta.type {
            case "thinking_delta":
                return consume(Delta(reasoning: delta.thinking))
            case "text_delta":
                return consume(Delta(text: delta.text))
            case "input_json_delta":
                return consume(Delta(
                    toolCallIndex: event.index ?? 0,
                    toolCallArguments: delta.partial_json
                ))
            default:
                return []
            }

        case "message_delta":
            if let output = event.usage?.output_tokens {
                // message_delta 只带输出侧用量，输入侧在 message_start 已计入
                setUsage(LLMUsage(promptTokens: 0, completionTokens: output, totalTokens: output))
            }
            setFinishReason(event.delta?.stop_reason)
            return []

        default:
            return []
        }
    }
}

/// 把任意 JSONValue 重新编码为字符串（用于 tool_use 的 input）
private struct WireJSONString {
    let value: String

    init(_ json: JSONValue) {
        if let data = try? JSONEncoder().encode(json), let text = String(data: data, encoding: .utf8) {
            self.value = text
        } else {
            self.value = "{}"
        }
    }
}

// MARK: - Wire 格式

private struct WireRequest: Encodable {
    let model: String
    let max_tokens: Int
    /// 开启 thinking 时不能传 temperature（Anthropic 要求省略或为 1）
    let temperature: Double?
    let system: String?
    let messages: [WireMessage]
    let tools: [WireTool]?
    let thinking: WireThinking?
    let stream: Bool

    init(request: LLMRequest, defaultModel: String, streaming: Bool = false) {
        let wantsThinking = request.thinkingEnabled == true
        let requestedMax = request.maxTokens ?? 2_048

        self.model = request.model ?? defaultModel
        // thinking 的 budget_tokens 必须小于 max_tokens
        self.max_tokens = wantsThinking ? max(requestedMax, 4_096) : requestedMax
        self.temperature = wantsThinking ? nil : request.temperature
        self.thinking = wantsThinking ? WireThinking(type: "enabled", budget_tokens: 2_048) : nil
        self.stream = streaming

        // system 消息抽出来作为独立字段
        let systemTexts = request.runtimeMessages()
            .filter { $0.role == .system }
            .map(\.content)
            .filter { !$0.isEmpty }
        self.system = systemTexts.isEmpty ? nil : systemTexts.joined(separator: "\n\n")

        self.messages = request.messages
            .filter { $0.role != .system }
            .map(WireMessage.init)

        self.tools = request.tools.isEmpty ? nil : request.tools.map(WireTool.init)
    }
}

private struct WireThinking: Encodable {
    let type: String
    let budget_tokens: Int
}

private struct WireTool: Encodable {
    let name: String
    let description: String
    let input_schema: JSONValue

    init(_ tool: LLMTool) {
        self.name = tool.name
        self.description = tool.description
        self.input_schema = tool.parameters
    }
}

private struct WireMessage: Encodable {
    let role: String
    let content: [Block]

    /// 内容块
    enum Block: Encodable {
        case text(String)
        case image(base64: String)
        case toolUse(id: String, name: String, input: JSONValue)
        case toolResult(id: String, content: String)
        case preserved(JSONValue)

        enum CodingKeys: String, CodingKey {
            case type, text, source, id, name, input, tool_use_id, content
        }

        struct Source: Encodable {
            let type = "base64"
            let media_type = "image/jpeg"
            let data: String
        }

        func encode(to encoder: Encoder) throws {
            if case .preserved(let value) = self { try value.encode(to: encoder); return }
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .preserved: break
            case .text(let value):
                try container.encode("text", forKey: .type)
                try container.encode(value, forKey: .text)
            case .image(let base64):
                try container.encode("image", forKey: .type)
                try container.encode(Source(data: base64), forKey: .source)
            case .toolUse(let id, let name, let input):
                try container.encode("tool_use", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(name, forKey: .name)
                try container.encode(input, forKey: .input)
            case .toolResult(let id, let content):
                try container.encode("tool_result", forKey: .type)
                try container.encode(id, forKey: .tool_use_id)
                try container.encode(content, forKey: .content)
            }
        }
    }

    init(_ message: LLMMessage) {
        // tool 结果在 Anthropic 协议里以 user 角色的 tool_result block 回传
        self.role = message.role == .tool ? "user" : message.role.rawValue

        if let callId = message.toolCallId {
            // tool_result 已承载文本，避免重复的 text block
            var blocks: [Block] = [.toolResult(id: callId, content: message.content)]
            blocks.append(contentsOf: message.imagesBase64JPEG.map { .image(base64: $0) })
            self.content = blocks
            return
        }

        var blocks: [Block] = message.thinkingBlocks.map { .preserved($0) }
        if !message.content.isEmpty {
            blocks.append(.text(message.content))
        }
        blocks.append(contentsOf: message.imagesBase64JPEG.map { .image(base64: $0) })
        blocks.append(contentsOf: message.toolCalls.map {
            .toolUse(id: $0.id, name: $0.name, input: $0.arguments ?? .object([:]))
        })
        self.content = blocks
    }
}

private struct WireResponse: Decodable {
    struct Block: Decodable {
        let type: String
        let text: String?
        let thinking: String?
        let signature: String?
        let data: String?
        let id: String?
        let name: String?
        let input: JSONValue?

        var continuationBlock: JSONValue? {
            if type == "thinking", let thinking, let signature {
                return .object(["type": .string(type), "thinking": .string(thinking), "signature": .string(signature)])
            }
            if type == "redacted_thinking", let data { return .object(["type": .string(type), "data": .string(data)]) }
            return nil
        }
    }

    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?

        var domain: LLMUsage {
            let input = input_tokens ?? 0
            let output = output_tokens ?? 0
            return LLMUsage(promptTokens: input, completionTokens: output, totalTokens: input + output)
        }
    }

    let content: [Block]?
    let stop_reason: String?
    let usage: Usage?
}

/// Signed thinking must be returned unchanged alongside the tool call.
/// These opaque blocks are not UI content and are never stored in chat history.
private struct AnthropicThinkingBlocks {
    private var values: [Int: [String: JSONValue]] = [:]
    var blocks: [JSONValue] { values.keys.sorted().compactMap { values[$0].map(JSONValue.object) } }

    mutating func consume(_ event: WireStreamEvent) {
        guard let index = event.index else { return }
        if event.type == "content_block_start", let block = event.content_block {
            if block.type == "thinking" {
                values[index] = ["type": .string("thinking"), "thinking": .string(block.thinking ?? ""), "signature": .string(block.signature ?? "")]
            } else if block.type == "redacted_thinking", let data = block.data {
                values[index] = ["type": .string("redacted_thinking"), "data": .string(data)]
            }
        } else if event.type == "content_block_delta", let delta = event.delta, values[index] != nil {
            let key: String, chunk: String
            if delta.type == "thinking_delta", let thinking = delta.thinking { key = "thinking"; chunk = thinking }
            else if delta.type == "signature_delta", let signature = delta.signature { key = "signature"; chunk = signature }
            else { return }
            let previous = values[index]?[key]?.stringValue ?? ""
            values[index]?[key] = .string(previous + chunk)
        }
    }
}
