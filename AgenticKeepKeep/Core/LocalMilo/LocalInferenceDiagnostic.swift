import Foundation

/// Only execution metadata. No prompts, answers, user records or file paths.
final class LocalInferenceDiagnostic: @unchecked Sendable {
    enum Stage: String { case checking = "文件检查", loading = "模型加载", preparing = "输入处理", prefill = "首字计算", decoding = "正文生成" }
    private let lock = NSLock()
    private var stage: Stage = .checking
    private var tokens: Int?
    private var peak: UInt64?
    private var vision = false
    func update(stage: Stage, tokens: Int? = nil, vision: Bool? = nil, footprint: UInt64?) {
        lock.lock(); defer { lock.unlock() }
        self.stage = stage
        if let tokens { self.tokens = tokens }
        if let vision { self.vision = vision }
        if let footprint { peak = max(peak ?? 0, footprint) }
    }
    func sample(footprint: UInt64?) {
        guard let footprint else { return }
        lock.lock(); defer { lock.unlock() }
        peak = max(peak ?? 0, footprint)
    }
    var summary: String {
        lock.lock(); defer { lock.unlock() }
        let input = tokens.map { "\($0) tokens" } ?? "尚未计数"
        let memory = peak.map { "\($0 / 1_048_576) MiB" } ?? "未取得"
        return "阶段：\(stage.rawValue)；路径：\(vision ? "图文" : "文字")；输入：\(input)；进程采样峰值：\(memory)。"
    }
}

struct LocalMemoryDiagnosticError: LocalizedError {
    let summary: String
    var errorDescription: String? {
        "系统发出内存警告，推理已停止（L14）。\(summary) 请反馈这段信息以定位原因。"
    }
}
