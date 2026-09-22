import Foundation
import MiloInferenceCore

typealias LocalInferenceDiagnostic = InferenceDiagnostic

struct LocalMemoryDiagnosticError: LocalizedError {
    let summary: String
    var errorDescription: String? {
        "系统发出内存警告，推理已停止（L14）。\(summary) 请反馈这段信息以定位原因。"
    }
}
