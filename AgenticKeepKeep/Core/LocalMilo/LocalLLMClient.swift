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
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let flag = LocalCancellation(), id = UUID()
            continuation.onTermination = { _ in flag.cancel() }
            lock.lock(); defer { lock.unlock() }
            if unloadCount > 0 { flag.cancel(reason: unloadReason) }
            cancellations[id] = flag
            let prior = tail
            tail = Task.detached { [self] in
                await prior?.value
                await generate(request, flag: flag, continuation: continuation)
                remove(id)
            }
        }
    }
    private func generate(_ request: LLMRequest, flag: LocalCancellation,
                          continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation) async {
        let diagnostic = LocalInferenceDiagnostic()
        diagnostic.update(stage: .checking, vision: request.messages.contains { !$0.imagesBase64JPEG.isEmpty }, footprint: nil)
        do {
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
            let output = LocalOutput(continuation: continuation, flag: flag)
            let result = try await InferenceEngine.shared.generate(InferenceRequest(directory: directory,
                input: input, budget: LocalMLXPolicy.budget, outputTokens: limit,
                temperature: Float(request.temperature)), cancellation: flag.inference, onText: { text in
                    if !request.jsonMode { output.replace(text) }
                })
            try flag.check()
            guard result.outputTokens < limit else { throw CoachContextError.truncated }
            if request.jsonMode { try LocalMLXPolicy.validateJSON(result.text) }
            let response = try LocalPrompt.parse(result.text, tools: request.tools)
            output.flush(response.content ?? "")
            for call in response.toolCalls { continuation.yield(.toolCall(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON)) }
            continuation.yield(.usage(LLMUsage(promptTokens: result.inputTokens, completionTokens: result.outputTokens,
                                              totalTokens: result.inputTokens + result.outputTokens)))
            continuation.yield(.finished(reason: response.toolCalls.isEmpty ? "stop" : "tool_calls"))
            continuation.finish()
        } catch {
            verified = false
            let execution = error as? InferenceExecutionError
            let failure = flag.cancelled ? flag.failure : Self.appError(execution?.underlying ?? error)
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

private final class LocalOutput: @unchecked Sendable {
    let continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    let flag: LocalCancellation
    var data = Data()
    var emitted = ""
    init(continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation, flag: LocalCancellation) {
        self.continuation = continuation; self.flag = flag
    }
    func replace(_ text: String) {
        data = Data()
        append(Data(text.utf8))
    }
    func append(_ bytes: Data) {
        guard !flag.cancelled else { return }
        data.append(bytes)
        guard data.count <= 131_072 else { flag.cancel(); return }
        guard let text = String(data: data, encoding: .utf8) else { return }
        // Keep a suffix until we know it is not a split control tag. Never render tool XML.
        let prefix = text.firstIndex(of: "<").map { String(text[..<$0]) } ?? String(text.dropLast(min(16, text.count)))
        flush(prefix)
    }
    func flush(_ text: String) {
        guard !flag.cancelled, text.hasPrefix(emitted), text.count > emitted.count else { return }
        continuation.yield(.text(String(text.dropFirst(emitted.count))))
        emitted = text
    }
}

struct LocalLLMClient: LLMClient {
    let config = LLMClientConfig(baseURL: "local://milo", apiKey: "", model: "Qwen3.5-0.8B-MLX-4bit")
    func complete(_ request: LLMRequest) async throws -> LLMResponse { try await LLMStreamCollector.collect(stream(request)).response }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> { LocalInferenceWorker.shared.stream(request) }
}
