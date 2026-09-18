import Foundation
import Combine

/// A single resumable file transfer. Delegate callbacks never touch SwiftUI state.
final class LocalModelTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var stopped = false
    private var moved: URL?
    private var moveError: Error?
    let file: LocalModelFile
    let directory: URL
    let progress: @Sendable (Int64) -> Void
    init(file: LocalModelFile, directory: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.file = file; self.directory = directory; self.progress = progress
    }
    var resumeURL: URL { directory.appendingPathComponent(file.name + ".modelscope.resume") }
    func run(cellular: Bool) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock(); defer { lock.unlock() }
                if stopped { cont.resume(throwing: CancellationError()); return }
                continuation = cont
                let configuration = URLSessionConfiguration.ephemeral
                configuration.allowsCellularAccess = cellular
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 7_200
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                if let resume = try? Data(contentsOf: resumeURL) { task = session.downloadTask(withResumeData: resume) }
                else { task = session.downloadTask(with: file.url) }
                task?.resume()
            }
        } onCancel: { self.pause() }
    }
    func pause() {
        lock.lock(); stopped = true; let task = task; lock.unlock()
        task?.cancel(byProducingResumeData: { _ in })
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > file.bytes || (totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite > file.bytes) {
            downloadTask.cancel()
        } else { progress(totalBytesWritten) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let http = downloadTask.response as? HTTPURLResponse, [200, 206].contains(http.statusCode) else {
                throw LocalMiloError.invalidFiles
            }
            let target = directory.appendingPathComponent(file.name + ".part")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
            moved = target
        } catch { moveError = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as NSError? {
            if let resume = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { try? resume.write(to: resumeURL, options: .atomic) }
            else { try? FileManager.default.removeItem(at: resumeURL) }
        } else { try? FileManager.default.removeItem(at: resumeURL) }
        lock.lock(); let cont = continuation; continuation = nil; self.task = nil; self.session = nil; lock.unlock()
        if let error = error ?? moveError { cont?.resume(throwing: error) }
        else if let moved { cont?.resume(returning: moved) }
        else { cont?.resume(throwing: LocalMiloError.invalidFiles) }
        session.finishTasksAndInvalidate()
    }
}

@MainActor
final class LocalModelStore: ObservableObject {
    static let shared = LocalModelStore()
    enum Phase: Equatable { case absent, downloading, paused, checking, ready, failed(String) }
    @Published private(set) var phase: Phase
    @Published private(set) var progress = 0.0
    @Published private(set) var isRemoving = false
    private var job: Task<Void, Never>?
    private var transfer: LocalModelTransfer?
    private var pauseRequested = false
    private var generation = UUID()
    var busy: Bool { job != nil || isRemoving }
    init() {
        phase = LocalModelManifest.isInstalled() ? .ready :
            (FileManager.default.fileExists(atPath: LocalModelManifest.directory.path) ? .paused : .absent)
    }
    func download(cellular: Bool) {
        guard !busy, phase != .ready else { return }
        pauseRequested = false
        let current = UUID(); generation = current
        phase = .downloading
        job = Task {
            defer { job = nil; transfer = nil }
            do {
                var folder = LocalModelManifest.directory
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try folder.setResourceValues(values)
                let available = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
                var existingSizes: [String: Int64] = [:]
                for file in LocalModelManifest.files {
                    if let size = try? folder.appendingPathComponent(file.name).resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        existingSizes[file.name] = Int64(size)
                    }
                }
                guard available > LocalModelManifest.requiredDownloadSpace(existingSizes: existingSizes) else {
                    throw LocalMiloError.insufficientSpace
                }
                var completed: Int64 = 0
                for file in LocalModelManifest.files {
                    try Task.checkCancellation()
                    if pauseRequested { throw CancellationError() }
                    let target = folder.appendingPathComponent(file.name)
                    if FileManager.default.fileExists(atPath: target.path) {
                        phase = .checking
                        do { try await verify(target, file: file) }
                        catch is CancellationError { throw CancellationError() }
                        catch { try? FileManager.default.removeItem(at: target); throw error }
                    } else {
                        phase = .downloading
                        let prior = completed
                        let transfer = LocalModelTransfer(file: file, directory: folder) { [weak self] count in
                            Task { @MainActor in
                                guard let self, self.generation == current, self.phase == .downloading else { return }
                                self.progress = Double(prior + count) / Double(LocalModelManifest.totalBytes)
                            }
                        }
                        self.transfer = transfer
                        let temp = try await transfer.run(cellular: cellular)
                        phase = .checking
                        do { try await verify(temp, file: file) }
                        catch { try? FileManager.default.removeItem(at: temp); throw error }
                        try FileManager.default.moveItem(at: temp, to: target)
                    }
                    completed += file.bytes
                    progress = Double(completed) / Double(LocalModelManifest.totalBytes)
                }
                try Task.checkCancellation()
                if pauseRequested { throw CancellationError() }
                try Data(LocalModelManifest.revision.utf8).write(to: folder.appendingPathComponent("ready"), options: .atomic)
                phase = .ready
                LLMSettings.shared.objectWillChange.send()
            } catch {
                phase = pauseRequested || Task.isCancelled ? .paused : .failed(error.localizedDescription)
            }
        }
    }
    private func verify(_ url: URL, file: LocalModelFile) async throws {
        let task = Task.detached(priority: .utility) { try LocalModelManifest.verify(url, file: file) }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func invalidate() {
        try? FileManager.default.removeItem(at: LocalModelManifest.directory.appendingPathComponent("ready"))
        phase = .failed(LocalMiloError.invalidFiles.localizedDescription)
        LLMSettings.shared.objectWillChange.send()
    }
    func pause() { pauseRequested = true; job?.cancel(); transfer?.pause() }
    func remove() async {
        guard !isRemoving else { return }
        isRemoving = true
        generation = UUID()
        pause()
        await job?.value
        try? FileManager.default.removeItem(at: LocalModelManifest.directory.appendingPathComponent("ready"))
        // Cancel active inference and wait for its serial worker to release file mappings.
        await LocalInferenceWorker.shared.unload()
        do {
            if FileManager.default.fileExists(atPath: LocalModelManifest.directory.path) {
                try FileManager.default.removeItem(at: LocalModelManifest.directory)
            }
            phase = .absent; progress = 0
        } catch { phase = .failed(error.localizedDescription) }
        isRemoving = false
        LLMSettings.shared.objectWillChange.send()
    }
}
