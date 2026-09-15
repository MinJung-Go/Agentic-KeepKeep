import Foundation

/// 累积流式增量。OpenAI 兼容协议与 Anthropic 协议共用同一份实现，
/// 避免两个客户端的拼接逻辑出现分歧；也便于单测（工具参数是分片到达的，拼接最容易出错）。
struct LLMStreamAccumulator {

    /// 归一化后的一个增量
    struct Delta {
        var text: String?
        var reasoning: String?
        /// 工具调用的序号（分片按 index 归组）
        var toolCallIndex: Int?
        var toolCallID: String?
        var toolCallName: String?
        var toolCallArguments: String?
    }

    private var text = ""
    private var reasoning = ""
    private var toolCalls: [Int: (id: String, name: String, arguments: String)] = [:]
    private var usage = LLMUsage()
    private var finishReason: String?

    var accumulatedText: String { text }
    var accumulatedReasoning: String { reasoning }

    /// 消费一个增量，返回可立即推送的事件
    mutating func consume(_ delta: Delta) -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []

        if let thinking = delta.reasoning, !thinking.isEmpty {
            reasoning += thinking
            events.append(.reasoning(thinking))
        }

        if let chunk = delta.text, !chunk.isEmpty {
            text += chunk
            events.append(.text(chunk))
        }

        if let index = delta.toolCallIndex {
            var entry = toolCalls[index] ?? (id: "", name: "", arguments: "")
            if let id = delta.toolCallID, !id.isEmpty { entry.id = id }
            if let name = delta.toolCallName, !name.isEmpty { entry.name = name }
            if let arguments = delta.toolCallArguments { entry.arguments += arguments }
            toolCalls[index] = entry
        }

        return events
    }

    /// 合并用量。Anthropic 会分两次上报（message_start 给输入、message_delta 给输出），
    /// 直接覆盖会丢掉先到的那一半。
    mutating func setUsage(_ value: LLMUsage) {
        if value.promptTokens > 0 { usage.promptTokens = value.promptTokens }
        if value.completionTokens > 0 { usage.completionTokens = value.completionTokens }
        usage.totalTokens = usage.promptTokens + usage.completionTokens
    }

    mutating func setFinishReason(_ value: String?) {
        finishReason = value
    }

    /// 流结束时输出：完整的工具调用 + 用量 + 结束事件
    mutating func finish() -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []

        for index in toolCalls.keys.sorted() {
            guard let call = toolCalls[index], !call.name.isEmpty else { continue }
            events.append(.toolCall(
                id: call.id.isEmpty ? UUID().uuidString : call.id,
                name: call.name,
                argumentsJSON: call.arguments.isEmpty ? "{}" : call.arguments
            ))
        }

        if usage.promptTokens > 0 || usage.completionTokens > 0 {
            events.append(.usage(usage))
        }
        events.append(.finished(reason: finishReason))

        return events
    }
}
