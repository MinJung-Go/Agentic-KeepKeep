import Foundation

/// 装饰器：把每次调用的 token 用量回传给设置（用于「用量统计」）
struct UsageRecordingClient: LLMClient {

    let base: LLMClient
    let onUsage: (LLMUsage) -> Void

    var config: LLMClientConfig { base.config }

    init(base: LLMClient, onUsage: @escaping (LLMUsage) -> Void) {
        self.base = base
        self.onUsage = onUsage
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let response = try await base.complete(request)
        onUsage(response.usage)
        return response
    }

    /// 流式调用：**原样透传**底层事件，只把 `.usage` 抄一份用于计数。
    ///
    /// 必须显式实现：`LLMClient` 协议扩展的默认 `stream()` 会退化成一次性请求，
    /// 在它的事件序列里根本没有 `.reasoning`。教练对话走的正是装饰过的客户端，
    /// 所以曾经既看不到思考过程、也不是真的逐字流式 —— 而单测用的 mock 自己实现了
    /// `stream()`，把这条路径绕过去了，于是一直没暴露。改这里时不要"顺手"把事件重组。
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let base = self.base
        let onUsage = self.onUsage

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in base.stream(request) {
                        if case .usage(let value) = event {
                            onUsage(value)
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
