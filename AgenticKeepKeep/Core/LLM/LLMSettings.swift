import Foundation
import CryptoKit

/// 端点预设
enum LLMEndpointPreset: String, CaseIterable, Identifiable {
    case zhipuGLM
    case openAI
    case anthropic
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zhipuGLM: return "智谱 GLM"
        case .openAI: return "OpenAI"
        case .anthropic: return "Claude（Anthropic）"
        case .custom: return "自定义（OpenAI 兼容）"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .zhipuGLM: return "https://open.bigmodel.cn/api/paas/v4"
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .zhipuGLM: return "glm-5.3-flash"
        case .openAI: return "gpt-4o-mini"
        case .anthropic: return "claude-sonnet-5"
        case .custom: return ""
        }
    }

    /// 该端点是否走 Anthropic 原生协议
    var usesAnthropicProtocol: Bool { self == .anthropic }
}

/// 当前请求使用鉴权云端代理；旧 BYOK 配置仅为恢复兼容而保留。
final class LLMSettings: ObservableObject {

    static let shared = LLMSettings()

    private enum Key {
        static let preset = "llm.preset"
        static let customBaseURL = "llm.customBaseURL"
        static let model = "llm.model"
        static let thinking = "llm.thinkingEnabled"
        static let usagePrompt = "llm.usage.promptTokens"
        static let usageCompletion = "llm.usage.completionTokens"
        static let callCount = "llm.usage.callCount"
    }

    private static let keychainAccount = "llm-api-key"

    private let defaults: UserDefaults

    @Published var useLocalModel: Bool {
        didSet {
            if !LocalModelAvailability.enabled && useLocalModel { useLocalModel = false }
            defaults.set(useLocalModel, forKey: "llm.useLocalModel")
        }
    }

    @Published var preset: LLMEndpointPreset {
        didSet { defaults.set(preset.rawValue, forKey: Key.preset) }
    }

    @Published var customBaseURL: String {
        didSet { defaults.set(customBaseURL, forKey: Key.customBaseURL) }
    }

    @Published var modelName: String {
        didSet { defaults.set(modelName, forKey: Key.model) }
    }

    /// 是否请求模型输出思考过程（智谱 GLM / Kimi / Claude 支持；不支持的模型请关掉）
    @Published var thinkingEnabled: Bool {
        didSet { defaults.set(thinkingEnabled, forKey: Key.thinking) }
    }

    @Published var webSearchEnabled: Bool {
        didSet { defaults.set(webSearchEnabled, forKey: "llm.webSearchEnabled") }
    }

    var supportsWebSearch: Bool {
        ServiceRuntime.shared.configuration?.searchEnabled == true
    }

    /// 仅在内存中保留；变更即写入 Keychain
    @Published var apiKey: String {
        didSet {
            if apiKey.isEmpty {
                KeychainStore.delete(account: Self.keychainAccount)
            } else {
                KeychainStore.set(apiKey, account: Self.keychainAccount)
            }
        }
    }

    @Published private(set) var usage: LLMUsage = LLMUsage()
    @Published private(set) var callCount: Int = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.useLocalModel = LocalModelAvailability.enabled && defaults.bool(forKey: "llm.useLocalModel")
        if !LocalModelAvailability.enabled { defaults.set(false, forKey: "llm.useLocalModel") }

        let storedPreset = defaults.string(forKey: Key.preset).flatMap(LLMEndpointPreset.init(rawValue:)) ?? .zhipuGLM
        self.preset = storedPreset
        self.customBaseURL = defaults.string(forKey: Key.customBaseURL) ?? ""
        self.modelName = defaults.string(forKey: Key.model) ?? storedPreset.defaultModel
        self.thinkingEnabled = defaults.object(forKey: Key.thinking) as? Bool ?? true
        self.webSearchEnabled = defaults.object(forKey: "llm.webSearchEnabled") as? Bool ?? true
        self.apiKey = KeychainStore.get(account: Self.keychainAccount) ?? ""
        self.callCount = defaults.integer(forKey: Key.callCount)
        self.usage = LLMUsage(
            promptTokens: defaults.integer(forKey: Key.usagePrompt),
            completionTokens: defaults.integer(forKey: Key.usageCompletion),
            totalTokens: 0
        )
        self.usage.totalTokens = usage.promptTokens + usage.completionTokens
    }

    /// 按端点和模型隔离窗口配置，不依赖模型名称猜测能力。
    var coachContextWindow: Int {
        get {
            let stored = defaults.integer(forKey: coachWindowKey)
            return stored == 0 ? 131_072 : stored
        }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: coachWindowKey)
        }
    }

    private var coachWindowKey: String {
        let legacyEndpoint = preset == .custom ? customBaseURL : preset.defaultBaseURL
        let identifier = legacyEndpoint + "\n" + modelName
        return "coach.window." + SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var coachPolicy: CoachContextPolicy {
        if useLocalModel {
            return CoachContextPolicy(window: LocalMLXPolicy.context, inputCap: LocalMLXPolicy.context,
                                      outputReserve: LocalMLXPolicy.maximumOutput,
                                      safetyMargin: 512, memoryLimit: 700, recentRounds: 2, queryResultReserve: 768,
                                      estimator: LocalTokenEstimator())
        }
        let config = ServiceRuntime.shared.configuration
        let window = config?.contextWindow ?? 32_768
        return CoachContextPolicy(window: window, inputCap: window, outputReserve: config?.maxOutput ?? 4096)
    }

    var baseURL: String { ServiceEndpoint.baseURL + "/v1" }

    var isConfigured: Bool {
        ServiceCredentials.session != nil && ServiceRuntime.shared.configuration?.model.isEmpty == false
    }

    /// 切换预设时，若模型名仍是旧预设默认值，则跟随切换
    func selectPreset(_ newValue: LLMEndpointPreset) {
        let oldDefault = preset.defaultModel
        if modelName.isEmpty || modelName == oldDefault {
            modelName = newValue.defaultModel
        }
        preset = newValue
    }

    /// 构造客户端（Agent 层唯一入口）
    func makeClient() throws -> LLMClient {
        guard let session = ServiceCredentials.session, let service = ServiceRuntime.shared.configuration,
              !service.model.isEmpty else { throw AuthServiceError(status: 401, message: "请先登录；如服务未就绪，请联系管理员。") }
        _ = try ServiceEndpoint.url("/chat/completions")
        let config = LLMClientConfig(baseURL: baseURL, apiKey: session.token, model: service.model,
                                     supportsStreamUsage: true)
        return OpenAICompatibleClient(config: config, session: ServiceTransport.shared.session)
    }

    /// 构造带用量记录的客户端（Agent 调用一律走这个）
    func makeRecordingClient() throws -> LLMClient {
        let token = ServiceCredentials.session?.token
        return UsageRecordingClient(base: try makeClient()) { [weak self] usage in
            Task { @MainActor in
                guard token == ServiceCredentials.session?.token else { return }
                self?.recordUsage(usage)
            }
        }
    }

    /// 记录一次调用的用量
    func recordUsage(_ value: LLMUsage) {
        usage = usage + value
        callCount += 1
        defaults.set(usage.promptTokens, forKey: Key.usagePrompt)
        defaults.set(usage.completionTokens, forKey: Key.usageCompletion)
        defaults.set(callCount, forKey: Key.callCount)
    }

    func reloadAccountUsage() {
        usage = LLMUsage(promptTokens: defaults.integer(forKey: Key.usagePrompt),
                         completionTokens: defaults.integer(forKey: Key.usageCompletion), totalTokens: 0)
        usage.totalTokens = usage.promptTokens + usage.completionTokens
        callCount = defaults.integer(forKey: Key.callCount)
    }

    func resetUsage() {
        usage = LLMUsage()
        callCount = 0
        defaults.set(0, forKey: Key.usagePrompt)
        defaults.set(0, forKey: Key.usageCompletion)
        defaults.set(0, forKey: Key.callCount)
    }

    /// 连接测试：发一条最小请求验证 Key 与端点可用
    func testConnection() async -> Result<String, Error> {
        do {
            let token = ServiceCredentials.session?.token
            let client = try makeClient()
            let response = try await client.complete(LLMRequest(
                messages: [.user("回复「ok」两个字符，不要有其他内容。")],
                temperature: 0,
                maxTokens: 32
            ))
            if token == ServiceCredentials.session?.token { recordUsage(response.usage) }
            let preview = (response.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(preview.isEmpty ? "连接正常" : "连接正常：\(preview.prefix(20))")
        } catch {
            return .failure(error)
        }
    }
}

/// Used only to plan pruning. The MLX tokenizer enforces LocalMLXPolicy.context before decode.
struct LocalTokenEstimator: CoachTokenEstimating {
    func count(_ text: String) -> Int {
        let scalars = text.unicodeScalars
        let ascii = scalars.filter(\.isASCII).count
        return max(1, (ascii + 2) / 3 + (scalars.count - ascii) * 2)
    }
}
