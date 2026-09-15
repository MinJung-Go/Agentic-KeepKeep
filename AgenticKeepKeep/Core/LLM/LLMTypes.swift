import Foundation

// MARK: - 与 wire 格式无关的领域类型

/// 一条对话消息
struct LLMMessage: Equatable {
    enum Role: String, Codable {
        case system, user, assistant, tool
    }

    var role: Role
    var content: String
    /// base64 编码的 JPEG（vision 场景）
    var imagesBase64JPEG: [String] = []
    /// assistant 发起的 function call
    var toolCalls: [LLMToolCall] = []
    /// tool 角色回传时的调用 id
    var toolCallId: String?
    /// Current tool exchange only; never copied to persistent history.
    var reasoning: String? = nil
    var thinkingBlocks: [JSONValue] = []

    static func system(_ content: String) -> LLMMessage {
        LLMMessage(role: .system, content: content)
    }

    static func user(_ content: String) -> LLMMessage {
        LLMMessage(role: .user, content: content)
    }

    static func assistant(_ content: String, toolCalls: [LLMToolCall] = []) -> LLMMessage {
        LLMMessage(role: .assistant, content: content, toolCalls: toolCalls)
    }

    static func tool(callId: String, content: String) -> LLMMessage {
        LLMMessage(role: .tool, content: content, toolCallId: callId)
    }

    /// 带图片的用户消息
    static func userWithImage(_ content: String, imageBase64JPEG: String) -> LLMMessage {
        LLMMessage(role: .user, content: content, imagesBase64JPEG: [imageBase64JPEG])
    }
}

/// 一次 function call
struct LLMToolCall: Codable, Equatable {
    var id: String
    var name: String
    /// 模型返回的原始参数 JSON 字符串
    var argumentsJSON: String

    var arguments: JSONValue? {
        JSONValue.parse(argumentsJSON)
    }
}

/// 一个可调用的工具（function call 定义）
struct LLMTool {
    var name: String
    var description: String
    var parameters: JSONValue
}

/// 一次补全请求
struct LLMRequest {
    var messages: [LLMMessage]
    var tools: [LLMTool] = []
    var temperature: Double = 0.2
    var maxTokens: Int?
    /// 要求模型输出 JSON 对象
    var jsonMode: Bool = false
    /// 覆盖设置中的默认模型
    var model: String?
    /// 是否要求输出思考过程（部分服务商支持；nil 表示不传该参数）
    var thinkingEnabled: Bool?

    init(
        messages: [LLMMessage],
        tools: [LLMTool] = [],
        temperature: Double = 0.2,
        maxTokens: Int? = nil,
        jsonMode: Bool = false,
        model: String? = nil,
        thinkingEnabled: Bool? = nil
    ) {
        self.messages = messages
        self.tools = tools
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.jsonMode = jsonMode
        self.model = model
        self.thinkingEnabled = thinkingEnabled
    }
}

/// token 用量
struct LLMUsage: Equatable {
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var totalTokens: Int = 0

    static func + (lhs: LLMUsage, rhs: LLMUsage) -> LLMUsage {
        LLMUsage(
            promptTokens: lhs.promptTokens + rhs.promptTokens,
            completionTokens: lhs.completionTokens + rhs.completionTokens,
            totalTokens: lhs.totalTokens + rhs.totalTokens
        )
    }
}

/// 一次补全结果
struct LLMResponse: Equatable {
    var content: String?
    var finishReason: String? = nil
    var toolCalls: [LLMToolCall] = []
    var usage: LLMUsage = LLMUsage()
    /// 思考内容（GLM / Kimi / DeepSeek 的 `reasoning_content`，或 Anthropic 的 thinking 块）。
    /// 一次性请求同样要留住它，否则只有流式路径能看到思考过程。
    var reasoning: String? = nil
    var thinkingBlocks: [JSONValue] = []

    static func text(_ content: String, usage: LLMUsage = LLMUsage()) -> LLMResponse {
        LLMResponse(content: content, toolCalls: [], usage: usage)
    }

    static func calls(_ toolCalls: [LLMToolCall], content: String? = nil, usage: LLMUsage = LLMUsage()) -> LLMResponse {
        LLMResponse(content: content, toolCalls: toolCalls, usage: usage)
    }
}

// MARK: - 流式

/// 流式事件
enum LLMStreamEvent: Equatable {
    /// 思考内容增量（GLM / Kimi / DeepSeek 的 reasoning_content，或 Anthropic 的 thinking_delta）
    case reasoning(String)
    /// Opaque signed/redacted provider blocks, transport only (never render).
    case continuationBlocks([JSONValue])
    /// 正文增量
    case text(String)
    /// 一个累积完整的工具调用（在流结束时给出）
    case toolCall(id: String, name: String, argumentsJSON: String)
    /// token 用量（服务商有返回时）
    case usage(LLMUsage)
    /// 结束
    case finished(reason: String?)
}

/// 流式累积结果
struct LLMStreamOutcome: Equatable {
    var text: String = ""
    var reasoning: String = ""
    var toolCalls: [LLMToolCall] = []
    var usage: LLMUsage = LLMUsage()
    var finishReason: String?
    var thinkingBlocks: [JSONValue] = []

    var response: LLMResponse {
        LLMResponse(
            content: text.isEmpty ? nil : text,
            finishReason: finishReason,
            toolCalls: toolCalls,
            usage: usage,
            reasoning: reasoning.isEmpty ? nil : reasoning,
            thinkingBlocks: thinkingBlocks
        )
    }
}

/// 把流式事件收集成一次完整结果（给不需要逐字渲染的场景用）
enum LLMStreamCollector {

    static func collect(_ stream: AsyncThrowingStream<LLMStreamEvent, Error>) async throws -> LLMStreamOutcome {
        var outcome = LLMStreamOutcome()

        for try await event in stream {
            switch event {
            case .reasoning(let chunk):
                outcome.reasoning += chunk
            case .continuationBlocks(let blocks):
                outcome.thinkingBlocks = blocks
            case .text(let chunk):
                outcome.text += chunk
            case .toolCall(let id, let name, let argumentsJSON):
                outcome.toolCalls.append(LLMToolCall(id: id, name: name, argumentsJSON: argumentsJSON))
            case .usage(let usage):
                outcome.usage = usage
            case .finished(let reason):
                outcome.finishReason = reason
            }
        }

        return outcome
    }
}

/// LLM 调用错误
enum LLMError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidEndpoint(String)
    case http(status: Int, body: String)
    case network(String)
    case decoding(String)
    case cancelled
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "尚未配置 API Key"
        case .invalidEndpoint(let value):
            return "端点地址无效：\(value)"
        case .http(let status, let body):
            return "服务返回错误（HTTP \(status)）：\(body)"
        case .network(let message):
            return "网络请求失败：\(message)"
        case .decoding(let message):
            return "返回内容解析失败：\(message)"
        case .cancelled:
            return "请求已取消"
        case .emptyResponse:
            return "模型没有返回内容"
        }
    }

    /// 是否值得重试
    var isRetryable: Bool {
        switch self {
        case .network, .emptyResponse:
            return true
        case .http(let status, _):
            return status >= 500
        default:
            return false
        }
    }
}

/// Agent 层错误
enum AgentError: LocalizedError, Equatable {
    case emptyResponse
    case invalidJSON(String)
    case emptyResult
    case missingToolCall(String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "模型没有返回内容"
        case .invalidJSON(let detail):
            return "模型返回的不是合法 JSON：\(detail)"
        case .emptyResult:
            return "模型没有识别出任何记录"
        case .missingToolCall(let name):
            return "模型未按要求调用工具：\(name)"
        }
    }
}
