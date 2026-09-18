import Foundation

enum LocalMiloError: LocalizedError, Equatable {
    case notReady, invalidFiles, insufficientSpace, runtime, image, budget, malformedTool
    var errorDescription: String? {
        switch self {
        case .notReady: return "请先下载完整的离线模型。照片和文字已保留。"
        case .invalidFiles: return "模型文件未通过检查，请重新下载。"
        case .insufficientSpace: return "存储空间不足，请释放空间后重试。"
        case .runtime: return "本机模型暂时无法运行，请重试。没有切换到云端。"
        case .image: return "这张照片暂时无法处理，请换一张或先用文字记录。"
        case .budget: return "这次内容超过本机模型容量，请缩短文字或减少图片。"
        case .malformedTool: return "模型未能生成完整有效的操作，尚未执行，请重试。"
        }
    }
}

