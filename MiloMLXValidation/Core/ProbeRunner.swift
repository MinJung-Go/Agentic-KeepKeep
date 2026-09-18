import Foundation
import Darwin
import MLX
import MLXLLM
import MLXLMCommon

/// A lock protects sampling while synchronous MLX generation owns its model context.
private final class MemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var points: [MemoryPoint] = []
    private let start = Date()
    func sample(_ stage: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let mlx = Memory.snapshot()
        let point = MemoryPoint(stage: stage, elapsed: Date().timeIntervalSince(start),
            footprint: result == KERN_SUCCESS ? info.phys_footprint : nil,
            available: UInt64(os_proc_available_memory()), mlxActive: mlx.activeMemory,
            mlxCache: mlx.cacheMemory, mlxPeak: mlx.peakMemory)
        lock.lock(); defer { lock.unlock() }
        // Bounded diagnostics, even if the runtime stalls for a long time.
        if points.count < 1800 { points.append(point) }
        else if stage != "sample" { points.append(point) }
    }
    func snapshot() -> [MemoryPoint] { lock.lock(); defer { lock.unlock() }; return points }
}

actor ProbeRunner {
    private var busy = false
    func run(directory: URL, revision: String, prompt: String, device: String, os: String,
             control: ProbeControl, update: @Sendable @escaping (String) -> Void) async -> ProbeReport {
        var report = ProbeReport(id: UUID(), date: Date(), device: device, os: os, revision: revision)
        guard !busy else { report.stop = .busy; return report }
        busy = true
        defer { busy = false }
        Memory.cacheLimit = 16 * 1_048_576
        Memory.clearCache()
        Memory.peakMemory = 0
        let sampler = MemorySampler()
        sampler.sample("beforeLoad")
        let sampling = Task.detached {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
                sampler.sample("sample")
            }
        }
        var container: ModelContainer?
        do {
            try control.check()
            let start = Date()
            update("加载模型…")
            container = try await LLMModelFactory.shared.loadContainer(configuration: ModelConfiguration(directory: directory))
            report.loadSeconds = Date().timeIntervalSince(start)
            sampler.sample("loaded")
            try control.check()
            // The synchronous API is deliberately pinned: returning means token evaluation
            // has stopped, so unload cannot race an AsyncStream producer.
            let result = try await container!.perform { context in
                let input = try await context.processor.prepare(input: UserInput(prompt: prompt, additionalContext: ["enable_thinking": false]))
                try ProbePolicy.validate(tokens: input.text.tokens.size)
                try control.check()
                sampler.sample("beforePrefill")
                let generationStart = Date()
                var first: Double?
                let generated = try MLXLMCommon.generate(input: input,
                    parameters: GenerateParameters(maxTokens: ProbePolicy.output, maxKVSize: ProbePolicy.context,
                        temperature: 0, prefillStepSize: 64), context: context) { tokens in
                    if control.reason != nil || Task.isCancelled { return .stop }
                    if first == nil { first = Date().timeIntervalSince(generationStart); sampler.sample("firstToken") }
                    update(context.tokenizer.decode(tokens: tokens))
                    return .more
                }
                return (generated.output, input.text.tokens.size, generated.tokens.count, first, generated.tokensPerSecond)
            }
            report.inputTokens = result.1
            report.outputTokens = result.2
            report.firstTokenSeconds = result.3
            report.tokensPerSecond = result.4.isFinite ? result.4 : nil
            report.stop = control.reason
            if report.stop == nil { update(result.0) }
            sampler.sample("generated")
        } catch {
            report.stop = control.reason ?? (error as? ProbeFailure) ?? (error is CancellationError ? .cancelled : .runtime)
            report.errorDomain = (error as NSError).domain
            report.errorCode = (error as NSError).code
        }
        container = nil
        Memory.clearCache()
        sampling.cancel()
        await sampling.value
        sampler.sample("unloaded")
        report.samples = sampler.snapshot()
        return report
    }
}
