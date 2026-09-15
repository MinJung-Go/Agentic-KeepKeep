import Foundation

/// Conservative local routing; uncertain input always remains editable.
enum HomeInputRouter {
    enum Destination: Equatable { case empty, chat, record, choose }
    static func destination(text: String, hasPhoto: Bool) -> Destination {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if hasPhoto { return .record }
        guard !text.isEmpty else { return .empty }
        let questions = ["?", "？", "多少", "什么", "哪些", "多久", "多长", "几次", "几组", "吗", "能否", "适合", "需要", "调整", "怎么", "如何", "为什么", "是否", "能不能", "可以吗", "查", "看看", "分析", "计划", "安排", "建议", "推荐", "删除", "修改", "取消", "不要记录", "别记录"]
        if questions.contains(where: text.contains) { return .chat }
        if ["记录一下", "帮我记录", "记一下", "记一笔"].contains(where: text.contains) { return .record }
        if ["吃了", "喝了", "跑了", "走了", "练了", "做了"].contains(where: text.contains) { return .record }
        if text.range(of: #"(体重|体脂)\s*[0-9]+"#, options: .regularExpression) != nil { return .record }
        let measured = #"(深蹲|卧推|硬拉|划船|推举|跑步|骑行|游泳).*[0-9]+\s*(kg|公斤|千克|公里|km|分钟|组|次|×|x|\*)"#
        if text.range(of: measured, options: .regularExpression) != nil { return .record }
        if ["你好", "谢谢", "累", "心情", "难过", "开心", "聊聊"].contains(where: text.contains) { return .chat }
        return .choose
    }
}
