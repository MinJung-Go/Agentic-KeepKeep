import Foundation
import MiloInference
import MiloInferenceCore

/// Keep application-specific stop reasons outside the reusable package.
final class LocalCancellation: @unchecked Sendable {
    let inference = InferenceCancellation()
    func cancel(reason: LocalMiloError? = nil) { inference.cancel(reason: reason) }
    var failure: Error { inference.failure }
    var cancelled: Bool { inference.cancelled }
    func check() throws { try inference.check() }
}

/// Marks whether the stream consumer is still attached; a degraded retry must not
/// generate into a terminated stream.
final class LocalConsumerState: @unchecked Sendable {
    var terminated = false
}

/// A task chain serializes async model loading as well as synchronous generation.
/// Cancelling a consumer signals its flag, but never skips awaiting the previous
/// task's cleanup. This prevents overlapping MLX containers across all Agents.
final class LocalInferenceWorker: @unchecked Sendable {
    static let shared = LocalInferenceWorker()
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var cancellations: [UUID: LocalCancellation] = [:]
    private var unloadCount = 0
    private var unloadReason: LocalMiloError?
    // Only accessed by the serialized task chain.
    private var verified = false

    func unload(reason: LocalMiloError? = nil) async {
        await enqueueUnload(reason: reason).value
    }
    private func enqueueUnload(reason: LocalMiloError?) -> Task<Void, Never> {
        lock.lock(); defer { lock.unlock() }
        unloadCount += 1; unloadReason = reason
        cancellations.values.forEach { $0.cancel(reason: reason) }
        let prior = tail
        let task = Task.detached { [self] in
            await prior?.value
            verified = false
            await InferenceEngine.shared.unload()
            finishUnload()
        }
        tail = task
        return task
    }
    private func finishUnload() {
        lock.lock(); defer { lock.unlock() }
        unloadCount -= 1
        if unloadCount == 0 { unloadReason = nil }
    }
    private func remove(_ id: UUID) { lock.lock(); defer { lock.unlock() }; cancellations.removeValue(forKey: id) }
    private func cancel(_ id: UUID) { lock.lock(); defer { lock.unlock() }; cancellations[id]?.cancel() }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let flag = LocalCancellation(), id = UUID()
            let consumer = LocalConsumerState()
            continuation.onTermination = { _ in
                consumer.terminated = true
                self.cancel(id)
            }
            lock.lock(); defer { lock.unlock() }
            if unloadCount > 0 { flag.cancel(reason: unloadReason) }
            cancellations[id] = flag
            let prior = tail
            tail = Task.detached { [self] in
                await prior?.value
                await generate(request, id: id, flag: flag, consumer: consumer, continuation: continuation)
                remove(id)
            }
        }
    }
    private func generate(_ request: LLMRequest, id: UUID, flag: LocalCancellation,
                          consumer: LocalConsumerState,
                          continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation) async {
        let diagnostic = LocalInferenceDiagnostic()
        diagnostic.update(stage: .checking, vision: request.messages.contains { !$0.imagesBase64JPEG.isEmpty }, footprint: nil)
        do {
            guard LocalModelAvailability.enabled else { throw LocalMiloError.notReady }
            try flag.check()
            guard LocalModelManifest.isInstalled() else { throw LocalMiloError.notReady }
            if !verified {
                for file in LocalModelManifest.files {
                    try LocalModelManifest.verify(LocalModelManifest.directory.appendingPathComponent(file.name), file: file, isCancelled: { flag.cancelled })
                }
                verified = true
            }
            try flag.check()
            let rendered = try LocalPrompt.render(request)
            let imageData = try Self.image(request.messages.flatMap(\.imagesBase64JPEG))
            let directory = try LocalModelManifest.runtimeDirectory()
            let input: InferenceInput
            if imageData.isEmpty {
                input = .rendered(rendered)
            } else {
                input = .vision(messages: try LocalMLXPolicy.visionMessages(rendered).map {
                    guard let role = $0["role"], let content = $0["content"] else { throw LocalMiloError.malformedTool }
                    return InferenceMessage(role: role, content: content)
                }, jpeg: imageData)
            }
            let limit = LocalMLXPolicy.outputLimit(request.maxTokens)
            let thinking = request.thinkingEnabled == true
            let output = LocalOutput(
                thinking: thinking,
                onReasoning: { continuation.yield(.reasoning($0)) },
                onText: { continuation.yield(.text($0)) },
                thinkingBudget: LocalMLXPolicy.thinkingBudget)
            output.onOverflow = { flag.cancel(reason: .thinkingUnconverged) }
            let temperature = thinking ? LocalMLXPolicy.thinkingTemperature : Float(request.temperature)
            let result = try await InferenceEngine.shared.generate(InferenceRequest(directory: directory,
                input: input, budget: LocalMLXPolicy.budget, outputTokens: limit,
                temperature: temperature), cancellation: flag.inference, onText: { text in
                    if !request.jsonMode { output.replace(text) }
                })
            try flag.check()
            // 思考未收敛：撞顶或自然结束前都没闭合 </think>，降级重试一次。
            // 模型若无视开块直接作答（无任何 think 标签），按正常回答处理。
            if thinking, result.text.contains("<think>"),
               (!output.thinkingClosed || output.answerText(result.text).isEmpty) {
                throw LocalMiloError.thinkingUnconverged
            }
            guard result.outputTokens < limit else { throw CoachContextError.truncated }
            let text: String
            if request.jsonMode {
                text = try LocalMLXPolicy.normalizedJSON(result.text)
            } else if thinking, output.thinkingClosed {
                text = output.answerText(result.text)
            } else {
                // 未开思考、或模型无视开块直接作答：整段都是正文。
                text = result.text
            }
            let response = try LocalPrompt.parse(text, tools: request.tools)
            output.flush(response.content ?? "")
            for call in response.toolCalls { continuation.yield(.toolCall(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON)) }
            continuation.yield(.usage(LLMUsage(promptTokens: result.inputTokens, completionTokens: result.outputTokens,
                                              totalTokens: result.inputTokens + result.outputTokens)))
            continuation.yield(.finished(reason: response.toolCalls.isEmpty ? "stop" : "tool_calls"))
            continuation.finish()
        } catch {
            let execution = error as? InferenceExecutionError
            let failure = flag.cancelled ? flag.failure : Self.appError(execution?.underlying ?? error)
            if (failure as? LocalMiloError) == .thinkingUnconverged, request.thinkingEnabled == true, !consumer.terminated {
                var fallback = request
                fallback.thinkingEnabled = false
                let fallbackFlag = LocalCancellation()
                lock.lock()
                let unloading = unloadCount > 0
                if !unloading { cancellations[id] = fallbackFlag }
                lock.unlock()
                guard !unloading else {
                    continuation.finish(throwing: unloadReason ?? LocalMiloError.runtime)
                    return
                }
                await generate(fallback, id: id, flag: fallbackFlag, consumer: consumer, continuation: continuation)
                return
            }
            verified = false
            if (failure as? LocalMiloError) == .invalidFiles { await MainActor.run { LocalModelStore.shared.invalidate() } }
            if (failure as? LocalMiloError) == .memoryPressure {
                continuation.finish(throwing: LocalMemoryDiagnosticError(summary: execution?.diagnostic ?? diagnostic.summary))
            } else { continuation.finish(throwing: failure) }
        }
    }
    private static func appError(_ error: Error) -> Error {
        guard let failure = error as? InferenceFailure else { return error }
        switch failure {
        case .budget: return LocalMiloError.budget
        case .modelLoad: return LocalMiloError.modelLoad
        case .visionLoad: return LocalMiloError.visionLoad
        case .image: return LocalMiloError.image
        case .integrity: return LocalMiloError.invalidFiles
        }
    }
    static func image(_ images: [String]) throws -> Data {
        do { return try InferenceImage.prepare(images) }
        catch { throw appError(error) }
    }

}

/// Splits a thinking-capable stream into reasoning and answer deltas. The engine
/// reports the full accumulated text per callback, so only the trailing control
/// tag can be split across callbacks; hold back a suffix until it resolves.
/// Pure string logic, no MLX, so the portable tests can cover it.
final class LocalOutput {
    private let thinking: Bool
    private let onReasoning: (String) -> Void
    private let onText: (String) -> Void
    private let thinkingBudget: Int
    var onOverflow: (() -> Void)?
    private(set) var thinkingClosed = false
    private var reasoningSent = ""
    private var textSent = ""
    private var reasoningCount = 0
    private var overflowed = false

    init(thinking: Bool, onReasoning: @escaping (String) -> Void,
         onText: @escaping (String) -> Void, thinkingBudget: Int) {
        self.thinking = thinking
        self.onReasoning = onReasoning; self.onText = onText; self.thinkingBudget = thinkingBudget
    }

    func replace(_ full: String) {
        guard !overflowed else { return }
        if thinking, !thinkingClosed {
            if let close = full.range(of: "</think>") {
                thinkingClosed = true
                var reasoning = String(full[..<close.lowerBound])
                if reasoning.hasPrefix("<think>") { reasoning.removeFirst("<think>".count) }
                // 尾部可能是被截断的 </think> 前缀，不属于思考内容。
                if let cut = reasoning.lastIndex(of: "<"), "</think>".hasPrefix(reasoning[cut...]) {
                    reasoning = String(reasoning[..<cut])
                }
                emitReasoning(reasoning, budgeted: false)
            } else {
                var reasoning = full.hasPrefix("<think>") ? String(full.dropFirst("<think>".count)) : full
                // 保留尾部 8 字符，避免 </think> 被切成两半漏进思考流。
                reasoning = String(reasoning.dropLast(min(8, reasoning.count)))
                emitReasoning(reasoning, budgeted: true)
            }
        }
        if !thinking || thinkingClosed { emitText(thinking ? answerText(full) : full) }
    }

    /// 首个 `</think>` 之后的正文；未闭合返回空串。
    func answerText(_ full: String) -> String {
        guard let close = full.range(of: "</think>") else { return "" }
        return String(full[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 补发正文尾部（jsonMode 不流式，不经过这里）。
    func flush(_ text: String) {
        guard text.hasPrefix(textSent), text.count > textSent.count else { return }
        onText(String(text.dropFirst(textSent.count)))
        textSent = text
    }

    private func emitReasoning(_ text: String, budgeted: Bool) {
        guard text.hasPrefix(reasoningSent), text.count > reasoningSent.count else { return }
        let delta = String(text.dropFirst(reasoningSent.count))
        reasoningCount += delta.count
        reasoningSent = text
        onReasoning(delta)
        if budgeted, !overflowed, reasoningCount >= thinkingBudget {
            overflowed = true
            onOverflow?()
        }
    }

    private func emitText(_ text: String) {
        guard !text.hasPrefix("<") else { return }
        let prefix = text.firstIndex(of: "<").map { String(text[..<$0]) } ?? text
        guard prefix.hasPrefix(textSent), prefix.count > textSent.count else { return }
        onText(String(prefix.dropFirst(textSent.count)))
        textSent = prefix
    }
}

struct LocalLLMClient: LLMClient {
    let config = LLMClientConfig(baseURL: "local://milo", apiKey: "", model: "Qwen3.5-0.8B-MLX-4bit")
    func complete(_ request: LLMRequest) async throws -> LLMResponse { try await LLMStreamCollector.collect(stream(request)).response }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> { LocalInferenceWorker.shared.stream(request) }
}
