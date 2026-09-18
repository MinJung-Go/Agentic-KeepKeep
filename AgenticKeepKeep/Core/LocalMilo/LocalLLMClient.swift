import Foundation
import ImageIO
import UniformTypeIdentifiers

final class LocalCancellation: @unchecked Sendable {
    let pointer = milo_cancel_create()!
    private let lock = NSLock()
    private var value = false
    private var reason: LocalMiloError?
    func cancel(reason: LocalMiloError? = nil) {
        lock.lock(); defer { lock.unlock() }
        if !value { self.reason = reason }
        value = true; milo_cancel_set(pointer)
    }
    var failure: Error {
        lock.lock(); defer { lock.unlock() }
        return reason.map { $0 as Error } ?? CancellationError()
    }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    deinit { milo_cancel_free(pointer) }
}

/// Native calls block this private serial queue, never MainActor. Shared by every Agent.
final class LocalInferenceWorker: @unchecked Sendable {
    static let shared = LocalInferenceWorker()
    private let queue = DispatchQueue(label: "moveliq.local-inference", qos: .userInitiated)
    private let lock = NSLock()
    private var cancellations: [UUID: LocalCancellation] = [:]
    private var engine: UnsafeMutableRawPointer?
    private var verified = false
    private var unloadCount = 0
    private var unloadReason: LocalMiloError?

    func unload(reason: LocalMiloError? = nil) async {
        lock.lock(); unloadCount += 1; unloadReason = reason
        let pending = Array(cancellations.values); lock.unlock()
        pending.forEach { $0.cancel(reason: reason) }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                if let engine = self.engine { milo_engine_free(engine) }
                self.engine = nil; self.verified = false
                self.lock.lock(); self.unloadCount -= 1
                if self.unloadCount == 0 { self.unloadReason = nil }
                self.lock.unlock()
                cont.resume()
            }
        }
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let flag = LocalCancellation(), id = UUID()
            lock.lock()
            if unloadCount > 0 { flag.cancel(reason: unloadReason) }
            cancellations[id] = flag
            lock.unlock()
            continuation.onTermination = { _ in flag.cancel() }
            queue.async {
                defer { self.lock.lock(); self.cancellations.removeValue(forKey: id); self.lock.unlock() }
                do {
                    guard !flag.cancelled else { throw flag.failure }
                    guard LocalModelManifest.isInstalled() else { throw LocalMiloError.notReady }
                    if !self.verified {
                        for file in LocalModelManifest.files {
                            try LocalModelManifest.verify(LocalModelManifest.directory.appendingPathComponent(file.name), file: file, isCancelled: { flag.cancelled })
                            if flag.cancelled { throw flag.failure }
                        }
                        self.verified = true
                    }
                    let prompt = try LocalPrompt.render(request)
                    let image = try Self.image(request.messages.flatMap(\.imagesBase64JPEG))
                    if self.engine == nil {
                        self.engine = milo_engine_create(
                            LocalModelManifest.directory.appendingPathComponent(LocalModelManifest.files[0].name).path,
                            LocalModelManifest.directory.appendingPathComponent(LocalModelManifest.files[1].name).path, flag.pointer)
                    }
                    guard !flag.cancelled else { throw flag.failure }
                    guard let engine = self.engine else { throw LocalMiloError.native(milo_last_error_code()) }
                    let output = LocalOutput(continuation: continuation, flag: flag)
                    let retained = Unmanaged.passUnretained(output).toOpaque()
                    var inputCount: Int32 = 0, outputCount: Int32 = 0
                    let generate = request.jsonMode ? milo_generate_json : milo_generate
                    let status = image.withUnsafeBytes { bytes in
                        generate(engine, prompt, bytes.bindMemory(to: UInt8.self).baseAddress, image.count,
                                      Int32(min(4096, max(1, request.maxTokens ?? 2048))), Float(request.temperature), flag.pointer,
                                      { bytes, count, context in
                                          guard let bytes, let context else { return }
                                          Unmanaged<LocalOutput>.fromOpaque(context).takeUnretainedValue().append(Data(bytes: bytes, count: count))
                                      }, retained, &inputCount, &outputCount)
                    }
                    guard !flag.cancelled, status != -3 else { throw flag.failure }
                    if status == -2 { throw LocalMiloError.budget }
                    if status == -4 { throw LocalMiloError.image }
                    guard status >= 0 else { throw LocalMiloError.native(status) }
                    guard let raw = String(data: output.data, encoding: .utf8) else { throw LocalMiloError.runtime }
                    if status == 1 { throw CoachContextError.truncated }
                    let response = try LocalPrompt.parse(raw, tools: request.tools)
                    output.flush(response.content ?? "")
                    for call in response.toolCalls { continuation.yield(.toolCall(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON)) }
                    continuation.yield(.usage(LLMUsage(promptTokens: Int(inputCount), completionTokens: Int(outputCount), totalTokens: Int(inputCount + outputCount))))
                    continuation.yield(.finished(reason: response.toolCalls.isEmpty ? "stop" : "tool_calls"))
                    continuation.finish()
                } catch {
                    let reportedError = flag.cancelled ? flag.failure : error
                    if (error as? LocalMiloError) == .invalidFiles {
                        Task { @MainActor in LocalModelStore.shared.invalidate() }
                    }
                    if let engine = self.engine { milo_engine_free(engine); self.engine = nil }
                    continuation.finish(throwing: reportedError)
                }
            }
        }
    }
    static func image(_ images: [String]) throws -> Data {
        guard images.count <= 1 else { throw LocalMiloError.image }
        guard let encoded = images.first else { return Data() }
        guard encoded.utf8.count <= 28_000_000, let data = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 768,
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
    let config = LLMClientConfig(baseURL: "local://milo", apiKey: "", model: "Qwen3.5-2B-Q4_K_M")
    func complete(_ request: LLMRequest) async throws -> LLMResponse { try await LLMStreamCollector.collect(stream(request)).response }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> { LocalInferenceWorker.shared.stream(request) }
}
