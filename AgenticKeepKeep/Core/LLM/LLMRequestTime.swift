import Foundation

/// Transport-only metadata: never appended to persisted chat or memory.
extension LLMRequest {
    func runtimeMessages(now: Date = .now, timeZone: TimeZone = .current) -> [LLMMessage] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: now)
        let date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let clock = String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        let offset = timeZone.secondsFromGMT(for: now)
        let zone = String(format: "%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, abs(offset) % 3600 / 60)
        let timestamp = date + "T" + clock + zone
        let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let weekday = weekdays[max(0, min(6, (parts.weekday ?? 1) - 1))]
        let metadata = """
        [请求时间] 当前设备时间：\(timestamp)；本地日期与星期：\(date) \(weekday)；时区：\(timeZone.identifier)。
        今天/昨天按此时区解释。此时间不是健康数据同步时间；无需向用户复述此元信息。
        """
        var result = messages
        if let index = result.firstIndex(where: { $0.role == .system }) {
            result[index].content += "\n" + metadata
        } else {
            result.insert(.system(metadata), at: 0)
        }
        return result
    }
}
