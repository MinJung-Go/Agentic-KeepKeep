import Foundation

protocol CoachTokenEstimating {
    func count(_ text: String) -> Int
}

/// Conservative UTF-8 byte estimate, not a provider tokenizer. Wire overhead and
/// a separate safety margin cover framing; explicit server overflow still has recovery.
struct CoachUTF8Estimator: CoachTokenEstimating {
    func count(_ text: String) -> Int { text.utf8.count }
}

struct CoachContextPolicy {
    var window: Int = 16_384
    var inputCap: Int = 12_000
    var outputReserve: Int = 4_096
    var safetyMargin: Int = 1_024
    var memoryLimit: Int = 1_500
    var recentRounds: Int = 6
    var estimator: any CoachTokenEstimating = CoachUTF8Estimator()

    func inputLimit(retrying: Bool = false) throws -> Int {
        guard window >= 4_096, window <= 1_048_576,
              outputReserve >= 4_096, outputReserve < window,
              safetyMargin >= 512, inputCap > 0, memoryLimit > 0, recentRounds > 0 else {
            throw CoachContextError.invalidBudget
        }
        let limit = min(inputCap, window - outputReserve - safetyMargin)
        guard limit > 0 else { throw CoachContextError.invalidBudget }
        return retrying ? Int(Double(limit) * 0.65) : limit
    }

    func tokens(_ request: LLMRequest) -> Int {
        var total = 256
        for message in request.runtimeMessages() {
            total += 64 + estimator.count(message.content)
            if !message.thinkingBlocks.isEmpty {
                total += (try? JSONEncoder().encode(message.thinkingBlocks).count) ?? 0
            } else { total += estimator.count(message.reasoning ?? "") }
            total += message.imagesBase64JPEG.reduce(0) { $0 + estimator.count($1) }
            for call in message.toolCalls {
                total += 64 + estimator.count(call.name) + estimator.count(call.argumentsJSON) + call.id.utf8.count
            }
        }
        for tool in request.tools {
            let schema = (try? JSONEncoder().encode(tool.parameters)) ?? Data()
            total += 64 + estimator.count(tool.name) + estimator.count(tool.description)
            total += estimator.count(String(decoding: schema, as: UTF8.self))
        }
        return total
    }

    func validate(_ request: LLMRequest, retrying: Bool = false) throws {
        guard tokens(request) <= (try inputLimit(retrying: retrying)) else {
            throw CoachContextError.tooLarge
        }
    }
}

enum CoachContextError: LocalizedError, Equatable {
    case invalidBudget, tooLarge, memoryUnavailable, invalidMemory, truncated
    var errorDescription: String? {
        switch self {
        case .invalidBudget: return "上下文容量配置无效，请在设置中调整 对话上下文容量。"
        case .tooLarge: return "这次输入或必要上下文过长，请拆分输入，或按模型实际能力调整上下文容量。原文已保留。"
        case .memoryUnavailable: return "暂时无法整理聊天记录，已保留原文和已有记忆，请稍后重试。"
        case .invalidMemory: return "聊天记忆校验失败，未覆盖已有记忆。"
        case .truncated: return "模型回复达到输出上限，已保留正文；未完成的计划不会执行，请缩小计划范围后重试。"
        }
    }
}

extension LLMError {
    var isContextOverflow: Bool {
        guard case .http(let status, let body) = self, [400, 413, 422].contains(status) else { return false }
        let text = body.lowercased()
        return ["context_length_exceeded", "prompt is too long", "prompt too long",
                "maximum context length", "exceeds the context window", "input is too long"].contains { text.contains($0) }
    }
}
