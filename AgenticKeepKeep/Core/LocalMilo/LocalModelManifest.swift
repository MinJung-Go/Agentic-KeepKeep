import Foundation
import CryptoKit

struct LocalModelFile: Codable, Equatable {
    let name: String
    let bytes: Int64
    let sha256: String
    var url: URL {
        URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/\(LocalModelManifest.revision)/\(name)")!
    }
}

enum LocalModelManifest {
    static let revision = "f6d5376be1edb4d416d56da11e5397a961aca8ae"
    static let files = [
        LocalModelFile(name: "Qwen3.5-2B-Q4_K_M.gguf", bytes: 1_280_835_840,
                       sha256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223"),
        LocalModelFile(name: "mmproj-F16.gguf", bytes: 668_227_264,
                       sha256: "7035e9cb8d7c6a9681d07eef9a364783e86ea4cd73faab2eabb4f43a101830c7")
    ]
    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    static var sizeLabel: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .decimal) }
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalMilo/\(revision)", isDirectory: true)
    }
    static func isInstalled(at directory: URL = directory) -> Bool {
        guard (try? String(contentsOf: directory.appendingPathComponent("ready"), encoding: .utf8)) == revision else { return false }
        return files.allSatisfy { file in
            (try? directory.appendingPathComponent(file.name).resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(file.bytes)
        }
    }
    static func verify(_ url: URL, file: LocalModelFile, isCancelled: () -> Bool = { false }) throws {
        guard (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(file.bytes) else { throw LocalMiloError.invalidFiles }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            if isCancelled() { throw CancellationError() }
            hash.update(data: chunk)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw LocalMiloError.invalidFiles }
    }
}
