import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreImage
import Darwin
import MLX
import MLXLLM
import MLXVLM
import MLXLMCommon

final class LocalCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var reason: LocalMiloError?
    func cancel(reason: LocalMiloError? = nil) {
        lock.lock(); defer { lock.unlock() }
        if !value { self.reason = reason }
        value = true
    }
    var failure: Error {
        lock.lock(); defer { lock.unlock() }
        return reason.map { $0 as Error } ?? CancellationError()
    }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func check() throws { if cancelled { throw failure } }
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
    private var hasUsedMLX = false

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
            if hasUsedMLX { Memory.clearCache() }
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
        var container: ModelContainer?
        let diagnostic = LocalInferenceDiagnostic()
        let sampling = Task.detached {
            while !Task.isCancelled {
                diagnostic.sample(footprint: Self.footprint())
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { break }
            }
        }
        defer {
            sampling.cancel()
            if hasUsedMLX { MLX.Stream.gpu.synchronize() }
            container = nil
            if hasUsedMLX { Memory.clearCache() }
        }
        do {
            diagnostic.update(stage: .checking, vision: request.messages.contains { !$0.imagesBase64JPEG.isEmpty }, footprint: Self.footprint())
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
            diagnostic.update(stage: .preparing, footprint: Self.footprint())
            let imageData = try Self.image(request.messages.flatMap(\.imagesBase64JPEG))
            let directory = try LocalModelManifest.runtimeDirectory()
            try flag.check()
            diagnostic.update(stage: .loading, vision: !imageData.isEmpty, footprint: Self.footprint())
            hasUsedMLX = true
            Memory.cacheLimit = 16 * 1_048_576
            Memory.clearCache()
            do {
                if imageData.isEmpty {
                    container = try await LLMModelFactory.shared.loadContainer(configuration: ModelConfiguration(directory: directory))
                } else {
                    container = try await VLMModelFactory.shared.loadContainer(configuration: ModelConfiguration(directory: directory))
                }
            } catch { throw imageData.isEmpty ? LocalMiloError.modelLoad : LocalMiloError.visionLoad }
            try flag.check()
            diagnostic.update(stage: .preparing, footprint: Self.footprint())
            let limit = LocalMLXPolicy.outputLimit(request.maxTokens)
            let output = LocalOutput(continuation: continuation, flag: flag)
            let result = try await container!.perform { context in
                let input: LMInput
                if imageData.isEmpty {
                    input = LMInput(tokens: MLXArray(context.tokenizer.encode(text: rendered)))
                } else {
                    guard let image = CIImage(data: imageData) else { throw LocalMiloError.image }
                    let messages: [[String: any Sendable]] = try LocalMLXPolicy.visionMessages(rendered).map { $0.mapValues { $0 as any Sendable } }
                    let userInput = UserInput(messages: messages, images: [.ciImage(image)], additionalContext: ["enable_thinking": false])
                    input = try await context.processor.prepare(input: userInput)
                }
                diagnostic.update(stage: .prefill, tokens: input.text.tokens.size, footprint: Self.footprint())
                try LocalMLXPolicy.validate(input: input.text.tokens.size, output: limit)
                try flag.check()
                let generated = try MLXLMCommon.generate(input: input,
                    parameters: GenerateParameters(maxTokens: limit, maxKVSize: LocalMLXPolicy.context,
                        temperature: Float(request.temperature), prefillStepSize: 64), context: context) { tokens in
                    diagnostic.update(stage: .decoding, footprint: Self.footprint())
                    guard !flag.cancelled else { return .stop }
                    // JSON and tools only execute after complete validation.
                    if !request.jsonMode { output.replace(context.tokenizer.decode(tokens: tokens)) }
                    return .more
                }
                return (generated.output, generated.promptTokenCount, generated.tokens.count)
            }
            try flag.check()
            guard result.2 < limit else { throw CoachContextError.truncated }
            if request.jsonMode { try LocalMLXPolicy.validateJSON(result.0) }
            let response = try LocalPrompt.parse(result.0, tools: request.tools)
            output.flush(response.content ?? "")
            for call in response.toolCalls { continuation.yield(.toolCall(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON)) }
            continuation.yield(.usage(LLMUsage(promptTokens: result.1, completionTokens: result.2, totalTokens: result.1 + result.2)))
            continuation.yield(.finished(reason: response.toolCalls.isEmpty ? "stop" : "tool_calls"))
            continuation.finish()
        } catch {
            verified = false
            if (error as? LocalMiloError) == .invalidFiles { await MainActor.run { LocalModelStore.shared.invalidate() } }
            diagnostic.sample(footprint: Self.footprint())
            let failure = flag.cancelled ? flag.failure : error
            if (failure as? LocalMiloError) == .memoryPressure {
                continuation.finish(throwing: LocalMemoryDiagnosticError(summary: diagnostic.summary))
            } else {
                continuation.finish(throwing: failure)
            }
        }
    }
    private static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : nil
    }
    static func image(_ images: [String]) throws -> Data {
        guard images.count <= 1 else { throw LocalMiloError.image }
        guard let encoded = images.first else { return Data() }
        guard encoded.utf8.count <= 28_000_000, let data = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 384,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw LocalMiloError.image }
        let output = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw LocalMiloError.image }
        CGImageDestinationAddImage(target, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { throw LocalMiloError.image }
        return output as Data
    }
}

private final class LocalOutput {
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
