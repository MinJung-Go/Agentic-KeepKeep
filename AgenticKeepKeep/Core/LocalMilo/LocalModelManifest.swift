import Foundation
import MiloInference

struct LocalModelFile: Codable, Equatable {
    let name: String
    let bytes: Int64
    let sha256: String
    var url: URL {
        URL(string: "https://modelscope.cn/models/mlx-community/Qwen3.5-0.8B-4bit/resolve/\(LocalModelManifest.modelScopeRevision)/\(name)")!
    }
}

enum LocalModelManifest {
    static let modelScopeRevision = "f607c492a6aeeb50ca73cca0b924c006331a02af"
    static let revision = "mlx-" + modelScopeRevision
    static let files = [
        LocalModelFile(name: "chat_template.jinja", bytes: 7755,
                       sha256: "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80"),
        LocalModelFile(name: "config.json", bytes: 3112,
                       sha256: "ba7770da23eae5ebd6827571f086e331956b33f4442a9e876fb4aa10969a6772"),
        LocalModelFile(name: "model.safetensors", bytes: 625229487,
                       sha256: "f5a0d9dd3efa73510542a8023d610ff26be2b4b020d181cfc4bedaa1fcc5dd9e"),
        LocalModelFile(name: "model.safetensors.index.json", bytes: 71473,
                       sha256: "6e48f2fa5d6f033a6d77bf833abfa9698ca24d1715ecea4c67447bcfaee44650"),
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
        do { return try ModelFiles.runtimeDirectory(at: directory, files: files.map(\.name)) }
        catch { throw LocalMiloError.invalidFiles }
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
        do {
            try ModelFiles.verify(url, bytes: file.bytes, sha256: file.sha256) {
                if isCancelled() { throw CancellationError() }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw LocalMiloError.invalidFiles }
    }
}
