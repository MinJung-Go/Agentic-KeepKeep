import Foundation

/// Persistent task identity rejects callbacks from removed/replaced installations.
enum LocalDownloadPolicy {
    static func descriptor(generation: String, file: String) -> String { generation + "|" + file }
    static func file(in descriptor: String?, generation: String, allowed: [String]) -> String? {
        guard let descriptor else { return nil }
        let parts = descriptor.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == generation, allowed.contains(String(parts[1])) else { return nil }
        return String(parts[1])
    }
    enum Recovery: Equatable { case installed, downloading, verify, paused, absent }
    static func recover(installed: Bool, activeTasks: Int, completeFiles: Int, expectedFiles: Int,
                        hasDirectory: Bool) -> Recovery {
        if installed { return .installed }
        if activeTasks > 0 { return .downloading }
        if expectedFiles > 0 && completeFiles == expectedFiles { return .verify }
        return hasDirectory ? .paused : .absent
    }
    static func progress(bytes: [String: Int64], expected: [String: Int64]) -> Double {
        let total = expected.values.reduce(Int64(0), +)
        guard total > 0 else { return 0 }
        let received = expected.reduce(Int64(0)) { $0 + min($1.value, max(0, bytes[$1.key] ?? 0)) }
        return Double(received) / Double(total)
    }
}
