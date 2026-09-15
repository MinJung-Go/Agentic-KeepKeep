import Foundation
import CryptoKit

struct CoachMemoryFact: Codable, Equatable {
    var sourceID: UUID
    var quote: String
}

struct CoachMemory: Codable, Equatable {
    static let currentVersion = 1
    var version = currentVersion
    var sessionID: UUID
    var coveredCount: Int
    var coveredDigest: String
    var facts: [CoachMemoryFact]

    static func stableID(_ turn: CoachTurn, index: Int) -> UUID {
        if let id = turn.id { return id }
        let text = "\(index)|\(turn.role.rawValue)|\(turn.date?.timeIntervalSince1970 ?? 0)|\(turn.content)"
        let hex = SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let a = Array(hex)
        let formatted = String(a[0..<8]) + "-" + String(a[8..<12]) + "-" + String(a[12..<16]) + "-" + String(a[16..<20]) + "-" + String(a[20..<32])
        return UUID(uuidString: formatted)!
    }

    static func digest(_ history: ArraySlice<CoachTurn>) -> String {
        var hash = SHA256()
        for turn in history {
            // Length framing avoids ambiguous concatenations. Reasoning is never in CoachTurn.
            let fields = [turn.id?.uuidString ?? "", turn.role.rawValue, turn.content,
                          String(turn.date?.timeIntervalSince1970 ?? 0)]
            for field in fields {
                hash.update(data: Data("\(field.utf8.count):\(field)".utf8))
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func isValid(for history: [CoachTurn]) -> Bool {
        guard version == Self.currentVersion, coveredCount > 0, coveredCount <= history.count,
              history.first?.id == sessionID,
              coveredDigest == Self.digest(history.prefix(coveredCount)) else { return false }
        let sources = Dictionary(history.prefix(coveredCount).compactMap { turn in turn.id.map { ($0, turn.content) } }, uniquingKeysWith: { first, _ in first })
        return facts.allSatisfy { !$0.quote.isEmpty && sources[$0.sourceID]?.contains($0.quote) == true }
    }

    func text(history: [CoachTurn]) -> String {
        let sources = Dictionary(history.compactMap { turn in turn.id.map { ($0, turn) } }, uniquingKeysWith: { first, _ in first })
        return facts.compactMap { fact -> String? in
            guard let turn = sources[fact.sourceID] else { return nil }
            let date = turn.date.map { ISO8601DateFormatter().string(from: $0) } ?? "日期未知"
            let speaker = turn.role == .user ? "用户明确表述" : "教练历史建议（不等于已执行）"
            return "[\(date) \(speaker)] \(fact.quote)"
        }.joined(separator: "\n")
    }
}
