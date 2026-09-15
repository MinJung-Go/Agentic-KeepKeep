import Foundation
@testable import AgenticKeepKeep

/// 测试用 LLM 客户端：按队列返回预设响应，并记录收到的请求
final class MockLLMClient: LLMClient {

    let config = LLMClientConfig(baseURL: "https://mock.local/v1", apiKey: "test-key", model: "mock-model")

    private var queued: [Result<LLMResponse, Error>]
    private(set) var requests: [LLMRequest] = []

    init(responses: [LLMResponse] = [], error: Error? = nil) {
        if let error {
            self.queued = [.failure(error)]
        } else {
            self.queued = responses.map { .success($0) }
        }
    }

    func enqueue(_ response: LLMResponse) {
        queued.append(.success(response))
    }

    func enqueue(error: Error) {
        queued.append(.failure(error))
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        requests.append(request)
        guard !queued.isEmpty else {
            throw LLMError.emptyResponse
        }
        switch queued.removeFirst() {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }

    // MARK: - 流式

    /// 预设的流式事件序列（为空时退化为协议默认实现）
    var streamEvents: [LLMStreamEvent] = []
    var streamError: Error?
    private(set) var streamRequests: [LLMRequest] = []

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        streamRequests.append(request)

        let events = streamEvents
        let error = streamError

        return AsyncThrowingStream { continuation in
            // 预设了事件就直接回放
            if !events.isEmpty || error != nil {
                for event in events {
                    continuation.yield(event)
                }
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
                return
            }

            // 没预设：用 complete 的结果切开（等价于协议默认实现）
            let task = Task {
                do {
                    let response = try await self.complete(request)
                    if let content = response.content, !content.isEmpty {
                        continuation.yield(.text(content))
                    }
                    for call in response.toolCalls {
                        continuation.yield(.toolCall(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON))
                    }
                    continuation.yield(.usage(response.usage))
                    continuation.yield(.finished(reason: nil))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 最近一次请求
    var lastRequest: LLMRequest? { requests.last }
}
