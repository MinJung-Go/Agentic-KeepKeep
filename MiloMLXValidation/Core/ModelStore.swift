import Foundation
import CryptoKit

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (String) -> Void
    init(update: @Sendable @escaping (String) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? " / \(totalBytesExpectedToWrite / 1_000_000) MB" : " MB"
        update("正在下载 · \(totalBytesWritten / 1_000_000)" + total)
    }
}

actor ModelStore {
    let manifest: ModelManifest
    let root: URL
    private var busy = false
    init() throws {
        guard let url = Bundle.main.url(forResource: "model-manifest", withExtension: "json") else { throw ProbeFailure.integrity }
        manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: url))
        try manifest.validate()
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MLXProbe/\(manifest.revision)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }
    private func valid(_ url: URL, file: ModelManifest.File, control: ProbeControl) throws -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.size] as? NSNumber)?.int64Value == file.size else { return false }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try control.check(); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
    }
    /// Revalidates even existing files before making the local-only runtime directory.
    func prepare(cellular: Bool, control: ProbeControl,
                 progress: @Sendable @escaping (String) -> Void) async throws -> URL {
        guard !busy else { throw ProbeFailure.busy }; busy = true; defer { busy = false }
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = cellular
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7200
        let session = URLSession(configuration: config, delegate: DownloadProgress(update: progress), delegateQueue: nil); defer { session.invalidateAndCancel() }
        for file in manifest.files {
            try control.check()
            let target = root.appendingPathComponent(file.name)
            progress("检查 \(file.name)")
            if try valid(target, file: file, control: control) { continue }
            let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            guard capacity > file.size + 256 * 1_048_576 else { throw ProbeFailure.diskSpace }
            progress("下载 \(file.name) · 完成的文件会保留")
            let (temporary, response) = try await session.download(from: manifest.url(for: file))
            defer { try? FileManager.default.removeItem(at: temporary) }
            try control.check()
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProbeFailure.network }
            progress("校验 \(file.name)")
            guard try valid(temporary, file: file, control: control) else { throw ProbeFailure.integrity }
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: temporary, to: target)
        }
        // Original, hashed tokenizer config lacks the separately stored Jinja template.
        // Build a derived directory: hard links avoid duplicating 1.7 GB of weights.
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        if FileManager.default.fileExists(atPath: runtime.path) { try FileManager.default.removeItem(at: runtime) }
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        for file in manifest.files where file.name != "tokenizer_config.json" {
            try FileManager.default.linkItem(at: root.appendingPathComponent(file.name), to: runtime.appendingPathComponent(file.name))
        }
        var tokenizer = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("tokenizer_config.json"))) as? [String: Any] ?? [:]
        tokenizer["chat_template"] = try String(contentsOf: root.appendingPathComponent("chat_template.jinja"), encoding: .utf8)
        try JSONSerialization.data(withJSONObject: tokenizer).write(to: runtime.appendingPathComponent("tokenizer_config.json"), options: .atomic)
        try control.check()
        return runtime
    }
}
