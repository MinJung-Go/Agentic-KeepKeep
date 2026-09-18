import Foundation

enum ProbeFailure: String, Error, Codable, Sendable {
    case cancelled, background, memoryWarning, budget, integrity, network, diskSpace, runtime, busy
}

/// First cause wins, including across UI and worker threads.
final class ProbeControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cause: ProbeFailure?
    func stop(_ reason: ProbeFailure) { lock.lock(); defer { lock.unlock() }; if cause == nil { cause = reason } }
    var reason: ProbeFailure? { lock.lock(); defer { lock.unlock() }; return cause }
    func check() throws { if let reason { throw reason }; try Task.checkCancellation() }
}

enum ProbePolicy {
    static let context = 2048
    static let output = 256
    static let prompts = ["你叫 Milo，是 Moveliq 的运动伙伴。请用一句话介绍自己。", "请把这些文字整理为一条记录：今天步行二十分钟。", "请用一句话解释为什么训练后需要休息。"]
    static func validate(tokens: Int) throws {
        guard tokens > 0, tokens <= context - output else { throw ProbeFailure.budget }
    }
}

struct ModelManifest: Codable, Sendable {
    struct File: Codable, Sendable { let name: String; let size: Int64; let sha256: String }
    let repository: String
    let revision: String
    let files: [File]
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    func validate() throws {
        guard repository == "mlx-community/Qwen3.5-2B-4bit", revision.count == 40,
              revision.allSatisfy({ $0.isHexDigit }), !files.isEmpty,
              Set(files.map(\.name)).count == files.count else { throw ProbeFailure.integrity }
        for file in files {
            guard !file.name.isEmpty, !file.name.contains("/"), !file.name.contains(".."),
                  file.size > 0, file.sha256.count == 64,
                  file.sha256.allSatisfy({ $0.isHexDigit }) else { throw ProbeFailure.integrity }
        }
    }
    func url(for file: File) -> URL {
        URL(string: "https://modelscope.cn/models/\(repository)/resolve/\(revision)/\(file.name)")!
    }
}

struct MemoryPoint: Codable, Sendable {
    let stage: String
    let elapsed: Double
    let footprint: UInt64?
    let available: UInt64
    let mlxActive: Int
    let mlxCache: Int
    let mlxPeak: Int
}

/// Intentionally no prompt, answer, file paths, keys, or user records.
struct ProbeReport: Codable, Sendable, Identifiable {
    let id: UUID
    let date: Date
    let device: String
    let os: String
    let revision: String
    var runtime = "MLX Swift 0.31.3 / MLX Swift LM 2.31.3"
    var inputTokens = 0
    var outputTokens = 0
    var loadSeconds: Double?
    var firstTokenSeconds: Double?
    var tokensPerSecond: Double?
    var stop: ProbeFailure?
    var errorDomain: String?
    var errorCode: Int?
    var samples: [MemoryPoint] = []
    var sampledPeakFootprint: UInt64? { samples.compactMap(\.footprint).max() }
}
