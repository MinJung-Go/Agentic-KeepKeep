import Foundation

/// 仅供界面回看的有序事件；思考仅来自服务商可展示输出，不保存查询参数或结果正文。
struct CoachToolActivity: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case running, completed, failed, cancelled }
    var id = UUID()
    /// nil 表示旧版工具事件，保持历史解码兼容。
    var kind: String? = nil
    var reasoning: String? = nil
    var title: String
    var status: Status = .running
    var duration: TimeInterval?

    mutating func finish(_ status: Status, since start: ContinuousClock.Instant) {
        self.status = status
        let elapsed = start.duration(to: .now).components
        duration = max(0, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }

    static func title(for call: LLMToolCall) -> String {
        if call.name == CoachTools.search.name { return "搜索公开健身资料" }
        if call.name == CoachTools.reader.name { return "阅读公开网页" }
        switch call.arguments?.objectValue?["kind"]?.stringValue {
        case "health": return "查询健康数据"
        case "training": return "查询训练记录"
        case "nutrition": return "查询饮食记录"
        case "body": return "查询身体指标"
        case "plan": return "查询课程表"
        default: return "查询本地记录"
        }
    }

    static func decode(_ json: String?) -> [Self] {
        guard let json, let values = try? JSONDecoder().decode([Self].self, from: Data(json.utf8)) else { return [] }
        return values
    }
}
