import Foundation

/// Original public vocabulary, not a third-party media dataset. Never transmit free-form notes.
struct TutorialExercise: Equatable {
    let name: String
    static let names = [
        "哑铃卧推", "杠铃卧推", "上斜哑铃卧推", "上斜杠铃卧推", "下斜哑铃卧推", "平板哑铃飞鸟",
        "哑铃侧平举", "哑铃前平举", "哑铃肩推", "杠铃推举", "坐姿哑铃推举", "哑铃弯举", "锤式弯举",
        "杠铃弯举", "绳索下压", "绳索面拉", "坐姿划船", "杠铃划船", "哑铃划船", "单臂哑铃划船",
        "高位下拉", "引体向上", "辅助引体向上", "杠铃深蹲", "徒手深蹲", "高脚杯深蹲", "保加利亚分腿蹲",
        "杠铃硬拉", "罗马尼亚硬拉", "哑铃罗马尼亚硬拉", "腿举", "腿屈伸", "俯卧腿弯举", "坐姿腿弯举",
        "臀桥", "杠铃臀推", "站姿提踵", "坐姿提踵", "俯卧撑", "窄距俯卧撑", "平板支撑", "侧平板支撑", "卷腹", "死虫式", "鸟狗式"
    ]
    static func resolve(_ raw: String) -> Self? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases = ["平板哑铃卧推": "哑铃卧推", "平板杠铃卧推": "杠铃卧推", "绳索三头下压": "绳索下压"]
        let canonical = aliases[name] ?? name
        return names.contains(canonical) ? Self(name: canonical) : nil
    }
    var query: String { "\(name) 教学 动作步骤 常见错误 安全 讲解 视频" }
    func matches(_ title: String) -> Bool {
        guard title.contains(name) else { return false }
        // A generic title must not silently match a more specific/different variation.
        for qualifier in ["上斜", "下斜", "单臂", "单腿", "窄距", "宽距", "反握", "辅助", "史密斯", "哑铃", "杠铃", "绳索", "壶铃"] {
            if title.contains(qualifier) && !name.contains(qualifier) { return false }
        }
        return true
    }
}

struct ExerciseTutorial: Codable, Identifiable, Equatable {
    var id: String { url.absoluteString }
    let title: String
    let url: URL
    let platform: String
    var author: String? = nil
    var reason: String

    static func platform(for url: URL) -> String? {
        guard GLMWebReader.isPublicURL(url), let host = url.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/")
        if ["www.bilibili.com", "bilibili.com", "m.bilibili.com"].contains(host),
           parts.count == 2, parts[0] == "video", parts[1].hasPrefix("BV") || parts[1].hasPrefix("av") { return "哔哩哔哩" }
        if ["www.youtube.com", "youtube.com", "m.youtube.com"].contains(host), url.path == "/watch",
           let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value,
           !id.isEmpty { return "YouTube" }
        return nil
    }

    static func decode(_ data: Data, exercise: TutorialExercise) throws -> [Self] {
        struct Response: Decodable {
            struct Item: Decodable { var title: String?; var content: String?; var link: String? }
            var search_result: [Item]?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        var values: [(Int, Self)] = []
        var seen = Set<String>()
        for item in response.search_result ?? [] {
            guard let title = item.title, exercise.matches(title), title.count <= 200,
                  let raw = item.link, let original = URL(string: raw), let platform = platform(for: original),
                  var components = URLComponents(url: original, resolvingAgainstBaseURL: false) else { continue }
            // Strip tracking and fragments; keep only the video identifier.
            components.fragment = nil
            components.queryItems = platform == "YouTube" ? components.queryItems?.filter { $0.name == "v" } : nil
            if platform == "哔哩哔哩" { components.host = "www.bilibili.com" }
            guard let url = components.url, seen.insert(url.absoluteString).inserted else { continue }
            let info = title + " " + (item.content ?? "")
            let teaching = ["教学", "讲解", "教程", "动作步骤"].contains { info.contains($0) }
            let correction = ["错误", "纠正", "安全", "注意", "要点"].contains { info.contains($0) }
            guard teaching, correction else { continue }
            let score = (platform == "哔哩哔哩" ? 10 : 0) + (["NSCA", "ACSM", "运动医学", "物理治疗"].contains { info.contains($0) } ? 2 : 0)
            values.append((score, Self(title: title, url: url, platform: platform,
                reason: "标题匹配\(exercise.name)，公开介绍包含教学及动作纠错或安全要点；创作者资质未独立核实。")))
        }
        return values.enumerated().sorted { a, b in a.element.0 == b.element.0 ? a.offset < b.offset : a.element.0 > b.element.0 }.prefix(3).map { $0.element.1 }
    }
}
