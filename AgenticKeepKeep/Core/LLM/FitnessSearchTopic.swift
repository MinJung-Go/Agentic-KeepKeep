import Foundation

/// A finite vocabulary prevents private chat/health values from becoming search queries.
enum FitnessSearchTopic: String, CaseIterable, Decodable {
    case strength, protein, sleep, cardio, fatLoss, recovery, mobility
    var query: String {
        switch self {
        case .strength: return "力量训练 增肌 训练量 系统综述 运动指南"
        case .protein: return "运动 蛋白质 摄入 系统综述 营养指南"
        case .sleep: return "睡眠 运动恢复 系统综述 指南"
        case .cardio: return "有氧运动 身体活动 WHO 指南"
        case .fatLoss: return "减脂 运动 能量平衡 系统综述 指南"
        case .recovery: return "力量训练 恢复 减量 系统综述"
        case .mobility: return "拉伸 关节活动度 运动 系统综述"
        }
    }
}

struct FitnessSearchArguments: Decodable {
    let topic: FitnessSearchTopic
    let count: Int?
}

