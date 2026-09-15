import Foundation

/// OpenAI 兼容协议的客户端（智谱 GLM / OpenAI / 任意兼容端点）
struct OpenAICompatibleClient: LLMClient {
    /// GLM-5.3 (including Flash) is thinking-only. Scope this to verified models.
    static func requiresThinking(model: String) -> Bool {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().split(separator: "/").last.map(String.init) ?? ""
        return name == "glm-5.3" || name.hasPrefix("glm-5.3-")
    }

    let config: LLMClientConfig
    private let session: URLSession

    init(config: LLMClientConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        guard !config.apiKey.isEmpty else { throw LLMError.missingAPIKey }
        guard let url = llmEndpointURL(base: config.baseURL, path: "/chat/completions") else {
            throw LLMError.invalidEndpoint(config.baseURL)
        }

        let body = try JSONEncoder().encode(WireRequest(request: request, defaultModel: config.model))
        let data = try await LLMHTTP.post(url: url, body: body, headers: authHeaders, config: config, session: session,
                                          refreshBody: { try JSONEncoder().encode(WireRequest(request: request, defaultModel: config.model)) })

        let decoded: WireResponse
        do {
            decoded = try JSONDecoder().decode(WireResponse.self, from: data)
        } catch {
            throw LLMError.decoding(error.localizedDescription)
        }

        guard let choice = decoded.choices.first else {
            throw LLMError.emptyResponse
        }

        let calls = (choice.message.tool_calls ?? []).compactMap { raw -> LLMToolCall? in
            guard let name = raw.function?.name, !name.isEmpty else { return nil }
            return LLMToolCall(
                id: raw.id ?? UUID().uuidString,
                name: name,
                argumentsJSON: raw.function?.arguments ?? "{}"
            )
        }

        return LLMResponse(
            content: choice.message.content,
            finishReason: choice.finish_reason,
            toolCalls: calls,
            usage: decoded.usage?.domain ?? LLMUsage(),
            reasoning: choice.message.thinkingText
        )
    }

    private var authHeaders: [String: String] {
        ["Authorization": "Bearer \(config.apiKey)"]
    }

    // MARK: - 流式

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !config.apiKey.isEmpty else { throw LLMError.missingAPIKey }
                    guard let url = llmEndpointURL(base: config.baseURL, path: "/chat/completions") else {
                        throw LLMError.invalidEndpoint(config.baseURL)
                    }

                    let body = try JSONEncoder().encode(WireRequest(
                        request: request,
                        defaultModel: config.model,
                        streaming: true,
                        includeUsage: config.supportsStreamUsage
                    ))

                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.timeoutInterval = config.timeout
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    for (key, value) in authHeaders {
                        urlRequest.setValue(value, forHTTPHeaderField: key)
                    }
                    urlRequest.httpBody = body

                    let (bytes, response) = try await session.bytes(for: urlRequest)

                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.network("响应格式异常")
                    }

                    guard (200...299).contains(http.statusCode) else {
                        // 错误响应是普通 JSON 而不是事件流，读一段用于提示
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 4_096 { break }
                        }
                        throw LLMError.http(status: http.statusCode, body: llmShortBody(data))
                    }

                    var accumulator = LLMStreamAccumulator()
                    let decoder = JSONDecoder()

                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty else { continue }
                        if payload == "[DONE]" { break }

                        guard let data = payload.data(using: .utf8),
                              let chunk = try? decoder.decode(WireStreamChunk.self, from: data) else {
                            continue
                        }

                        for event in accumulator.consume(chunk) {
                            continuation.yield(event)
                        }
                    }

                    for event in accumulator.finish() {
                        continuation.yield(event)
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

// MARK: - Wire 格式（仅本文件使用）

private struct WireRequest: Encodable {
    let model: String
    let messages: [WireMessage]
    let temperature: Double
    let max_tokens: Int?
    let tools: [WireTool]?
    let tool_choice: String?
    let response_format: WireResponseFormat?
    let stream: Bool
    let stream_options: WireStreamOptions?
    /// 智谱 GLM 等支持 {"thinking": {"type": "enabled"}}
    let thinking: WireThinking?
    let reasoning_effort: String?

    init(request: LLMRequest, defaultModel: String, streaming: Bool = false, includeUsage: Bool = false) {
        self.model = request.model ?? defaultModel
        self.messages = request.runtimeMessages().map(WireMessage.init)
        self.temperature = request.temperature
        self.max_tokens = request.maxTokens
        self.tools = request.tools.isEmpty ? nil : request.tools.map(WireTool.init)
        self.tool_choice = request.tools.isEmpty ? nil : "auto"
        self.response_format = request.jsonMode ? WireResponseFormat(type: "json_object") : nil
        self.stream = streaming
        self.stream_options = (streaming && includeUsage) ? WireStreamOptions(include_usage: true) : nil
        let parts = self.model.lowercased().split(separator: "-")
        let version = parts.count > 1 ? parts[1].split(separator: ".").compactMap { Int($0) } : []
        let supportsEffort = parts.first == "glm" && !version.isEmpty &&
            (version[0] > 5 || (version[0] == 5 && version.count > 1 && version[1] >= 2))
        if OpenAICompatibleClient.requiresThinking(model: self.model) {
            // Never emit disabled/medium: 5.3 accepts low/high/max only.
            self.reasoning_effort = request.thinkingEnabled == false ? "low" : "high"
            self.thinking = WireThinking(type: "enabled")
        } else if supportsEffort, request.thinkingEnabled == false {
            self.reasoning_effort = nil
            self.thinking = WireThinking(type: "disabled")
        } else {
            self.reasoning_effort = supportsEffort ? "medium" : nil
            self.thinking = request.thinkingEnabled == true ? WireThinking(type: "enabled") : nil
        }
    }
}

private struct WireStreamOptions: Encodable {
    let include_usage: Bool
}

private struct WireThinking: Encodable {
    let type: String
}

/// 流式响应分片
private struct WireStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct ToolCallFragment: Decodable {
                struct Function: Decodable {
                    let name: String?
                    let arguments: String?
                }
                let index: Int?
                let id: String?
                let function: Function?
            }

            let content: String?
            let reasoning_content: String?
            let reasoning: String?
            let tool_calls: [ToolCallFragment]?

            /// 不同服务商对思考内容的字段命名
            var thinkingText: String? { reasoning_content ?? reasoning }
        }

        let delta: Delta?
        let finish_reason: String?
    }

    let choices: [Choice]?
    let usage: WireResponse.Usage?
}

extension LLMStreamAccumulator {

    /// 把 OpenAI 兼容协议的流式分片归一化后交给累积器
    fileprivate mutating func consume(_ chunk: WireStreamChunk) -> [LLMStreamEvent] {
        if let value = chunk.usage {
            setUsage(value.domain)
        }

        guard let choice = chunk.choices?.first else { return [] }
        setFinishReason(choice.finish_reason)

        guard let delta = choice.delta else { return [] }

        let fragments = delta.tool_calls ?? []
        var events = consume(Delta(
            text: delta.content,
            reasoning: delta.thinkingText,
            toolCallIndex: fragments.first?.index,
            toolCallID: fragments.first?.id,
            toolCallName: fragments.first?.function?.name,
            toolCallArguments: fragments.first?.function?.arguments
        ))

        // 一次分片里出现多个工具调用时继续消费其余部分
        for fragment in fragments.dropFirst() {
            events += consume(Delta(
                toolCallIndex: fragment.index,
                toolCallID: fragment.id,
                toolCallName: fragment.function?.name,
                toolCallArguments: fragment.function?.arguments
            ))
        }

        return events
    }
}

private struct WireResponseFormat: Encodable {
    let type: String
}

private struct WireTool: Encodable {
    let type = "function"
    let function: WireFunction

    init(_ tool: LLMTool) {
        self.function = WireFunction(
            name: tool.name,
            description: tool.description,
            parameters: tool.parameters
        )
    }
}

private struct WireFunction: Encodable {
    let name: String
    let description: String
    let parameters: JSONValue
}

private struct WireMessage: Encodable {
    let role: String
    let content: WireContent?
    let tool_calls: [WireOutgoingToolCall]?
    let tool_call_id: String?
    let reasoning_content: String?

    init(_ message: LLMMessage) {
        self.reasoning_content = message.reasoning
        self.role = message.role.rawValue
        if message.imagesBase64JPEG.isEmpty {
            self.content = .text(message.content)
        } else {
            var parts: [WireContentPart] = [.text(message.content)]
            parts.append(contentsOf: message.imagesBase64JPEG.map { .image(jpegBase64: $0) })
            self.content = .parts(parts)
        }
        self.tool_calls = message.toolCalls.isEmpty ? nil : message.toolCalls.map(WireOutgoingToolCall.init)
        self.tool_call_id = message.toolCallId
    }
}

private enum WireContent: Encodable {
    case text(String)
    case parts([WireContentPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value):
            try container.encode(value)
        case .parts(let value):
            try container.encode(value)
        }
    }
}

private enum WireContentPart: Encodable {
    case text(String)
    case image(jpegBase64: String)

    enum CodingKeys: String, CodingKey {
        case type, text, image_url
    }

    struct ImageURL: Encodable {
        let url: String
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case .image(let base64):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURL(url: "data:image/jpeg;base64,\(base64)"), forKey: .image_url)
        }
    }
}

private struct WireOutgoingToolCall: Encodable {
    let id: String
    let type = "function"
    let function: Function

    struct Function: Encodable {
        let name: String
        let arguments: String
    }

    init(_ call: LLMToolCall) {
        self.id = call.id
        self.function = Function(name: call.name, arguments: call.argumentsJSON)
    }
}

private struct WireResponse: Decodable {
    struct Choice: Decodable {
        let message: Message
        let finish_reason: String?
    }

    struct Message: Decodable {
        struct ToolCall: Decodable {
            struct Function: Decodable {
                let name: String?
                let arguments: String?
            }
            let id: String?
            let type: String?
            let function: Function?
        }

        let role: String?
        let content: String?
        let reasoning_content: String?
        let reasoning: String?
        let tool_calls: [ToolCall]?

        /// 不同服务商对思考内容的字段命名（与流式分片保持一致）
        var thinkingText: String? { reasoning_content ?? reasoning }
    }

    struct Usage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?

        var domain: LLMUsage {
            LLMUsage(
                promptTokens: prompt_tokens ?? 0,
                completionTokens: completion_tokens ?? 0,
                totalTokens: total_tokens ?? ((prompt_tokens ?? 0) + (completion_tokens ?? 0))
            )
        }
    }

    let choices: [Choice]
    let usage: Usage?
}
