import Foundation

enum LocalMiloError: LocalizedError, Equatable {
    case notReady, invalidFiles, insufficientSpace, runtime, image, budget, malformedTool
    case modelLoad, contextLoad, visionLoad, evaluation
    case memoryPressure, backgrounded
    static func native(_ code: Int32) -> LocalMiloError {
        switch code {
        case -10: return .modelLoad
        case -11: return .contextLoad
        case -12: return .visionLoad
        case -13: return .evaluation
        case -2: return .budget
        case -4: return .image
        default: return .runtime
        }
    }
    var errorDescription: String? {
        switch self {
        case .notReady: return "请先下载新版 MLX 离线模型；旧版模型格式不兼容。照片和文字已保留。"
        case .invalidFiles: return "模型文件未通过检查，请重新下载。"
        case .insufficientSpace: return "存储空间不足，请释放空间后重试。"
        case .memoryPressure: return "系统发出内存警告，本地推理已停止（L14）。请关闭其他大型 App 后重试；若持续出现，当前模型可能超出设备可用内存。"
        case .backgrounded: return "App 进入后台，本地推理已暂停（L15）。请保持 App 在前台后重试。"
        case .modelLoad: return "语言模型加载失败（L10）。请关闭其他大型 App 后重试；若仍失败，请反馈设备型号与此编号。"
        case .contextLoad: return "本机推理初始化失败（L11），可能是可用内存不足或计算后端不兼容。请关闭其他大型 App 后重试。"
        case .visionLoad: return "看图组件加载失败（L12），请先尝试纯文字。没有切换到云端。"
        case .evaluation: return "本机计算失败（L13），请缩短内容后重试；若仍失败，请反馈此编号。"
        case .runtime: return "本机模型暂时无法运行，请重试。没有切换到云端。"
        case .image: return "这张照片暂时无法处理，请换一张或先用文字记录。"
        case .budget: return "这次内容超过本机模型容量，请缩短文字或减少图片。"
        case .malformedTool: return "模型未能生成完整有效的操作，尚未执行，请重试。"
        }
    }
}

