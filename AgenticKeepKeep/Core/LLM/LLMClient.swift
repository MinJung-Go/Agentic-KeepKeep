import Foundation

/// LLM 客户端配置
struct LLMClientConfig: Equatable {
    var baseURL: String
    var apiKey: String
    var model: String
    var timeout: TimeInterval = 60
    var maxRetries: Int = 1
    /// 服务商是否支持 stream_options.include_usage（不支持的端点带上可能报错）
    var supportsStreamUsage: Bool = false
}

/// LLM 客户端协议。所有 Agent 只依赖这一层，便于替换与 mock 测试。
protocol LLMClient {
    var config: LLMClientConfig { get }
    /// 发起一次补全（含 function calling）
    func complete(_ request: LLMRequest) async throws -> LLMResponse
    /// 流式补全（思考内容与正文增量）
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error>
}

extension LLMClient {
    /// 默认实现：客户端没实现流式时，退化为一次性请求再切开推送
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)

                    if let reasoning = response.reasoning { continuation.yield(.reasoning(reasoning)) }
                    if !response.thinkingBlocks.isEmpty { continuation.yield(.continuationBlocks(response.thinkingBlocks)) }
                    if let content = response.content, !content.isEmpty {
                        continuation.yield(.text(content))
                    }
                    for call in response.toolCalls {
                        continuation.yield(.toolCall(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON))
                    }
                    continuation.yield(.usage(response.usage))
                    continuation.yield(.finished(reason: response.finishReason))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 拼接端点 URL（baseURL + 路径），容忍结尾斜杠
func llmEndpointURL(base: String, path: String) -> URL? {
    var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasSuffix("/") {
        trimmed.removeLast()
    }
    guard !trimmed.isEmpty, let url = URL(string: trimmed + path), url.scheme != nil, url.host != nil else {
        return nil
    }
    return url
}

/// 截断错误响应体，避免把整页 HTML 塞进错误信息
func llmShortBody(_ data: Data, limit: Int = 300) -> String {
    let text = String(data: data, encoding: .utf8) ?? "<非文本响应>"
    if text.count <= limit { return text }
    return String(text.prefix(limit)) + "…"
}
