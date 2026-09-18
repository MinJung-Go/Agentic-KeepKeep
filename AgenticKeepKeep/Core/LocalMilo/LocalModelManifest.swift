import Foundation
import CryptoKit

struct LocalModelFile: Codable, Equatable {
    let name: String
    let bytes: Int64
    let sha256: String
    var url: URL {
        URL(string: "https://modelscope.cn/models/mlx-community/Qwen3.5-2B-4bit/resolve/\(LocalModelManifest.modelScopeRevision)/\(name)")!
    }
}

enum LocalModelManifest {
    static let modelScopeRevision = "ffa48c63955c56e22d76c1b2acd9b89e26310618"
    static let revision = "mlx-" + modelScopeRevision
    static let files = [
        LocalModelFile(name: "chat_template.jinja", bytes: 7755,
                       sha256: "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80"),
        LocalModelFile(name: "config.json", bytes: 3113,
                       sha256: "beb7fc5a6e0405fe332821cf1a8ef7b69bb390a8c8933171647de5579debf949"),
        LocalModelFile(name: "model.safetensors", bytes: 1722271785,
                       sha256: "713fe7e5d3c3965f7106b0d0ee17615f7869c23c8d327996df8c1196fbcf07d5"),
        LocalModelFile(name: "model.safetensors.index.json", bytes: 81722,
                       sha256: "8294c05cca7d53a6c33e3db2b379539bd296d054e0b689711b16b6ac93c7e49d"),
        LocalModelFile(name: "preprocessor_config.json", bytes: 390,
                       sha256: "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516"),
        LocalModelFile(name: "processor_config.json", bytes: 1300,
                       sha256: "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b"),
        LocalModelFile(name: "tokenizer.json", bytes: 19989343,
                       sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
        LocalModelFile(name: "tokenizer_config.json", bytes: 1139,
                       sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182")
    ]
    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    static var sizeLabel: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .decimal) }
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalMilo/\(revision)", isDirectory: true)
    }
    static func runtimeDirectory() throws -> URL {
        let runtime = directory.appendingPathComponent("runtime", isDirectory: true)
        if FileManager.default.fileExists(atPath: runtime.path) { try FileManager.default.removeItem(at: runtime) }
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        for file in files where file.name != "tokenizer_config.json" {
            try FileManager.default.linkItem(at: directory.appendingPathComponent(file.name), to: runtime.appendingPathComponent(file.name))
        }
        guard var config = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("tokenizer_config.json"))) as? [String: Any] else { throw LocalMiloError.invalidFiles }
        config["chat_template"] = try String(contentsOf: directory.appendingPathComponent("chat_template.jinja"), encoding: .utf8)
        try JSONSerialization.data(withJSONObject: config).write(to: runtime.appendingPathComponent("tokenizer_config.json"), options: .atomic)
        return runtime
    }
    static func requiredDownloadSpace(existingSizes: [String: Int64]) -> Int64 {
        files.filter { existingSizes[$0.name] != $0.bytes }.reduce(Int64(268_435_456)) { $0 + $1.bytes }
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
