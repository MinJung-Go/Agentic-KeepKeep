import Foundation
import Combine
import UIKit

/// Delegate runs on its own serial queue. Handoff is synchronous so the temporary
/// file is moved before the callback returns, and finish-events follows all disk writes.
private final class LocalDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private func deliver(_ body: @MainActor () -> Void) {
        DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        deliver { LocalModelStore.shared.received(downloadTask, at: location) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        deliver { LocalModelStore.shared.updated(downloadTask, bytes: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        deliver { LocalModelStore.shared.completed(task, error: error) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        deliver { LocalModelStore.shared.finishedEvents(identifier: session.configuration.identifier) }
    }
}

@MainActor
final class LocalModelStore: ObservableObject {
    static let shared = LocalModelStore()
    static let sessionPrefix = "com.minjung.keepkeep.local-model.modelscope.v1"
    static let sessionIDs = [sessionPrefix + ".wifi", sessionPrefix + ".cellular"]
    // Keep session IDs stable to reconnect and cancel obsolete transfers.
    // Persist intent and identity per model revision: filenames alone are shared.
    static let generationKey = "localMilo.mlx.backgroundGeneration.\(LocalModelManifest.revision)"
    static let activeKey = "localMilo.mlx.backgroundDownloadActive.\(LocalModelManifest.revision)"
    enum Phase: Equatable { case absent, downloading, paused, checking, ready, failed(String) }
    @Published private(set) var phase: Phase
    @Published private(set) var progress = 0.0
    @Published private(set) var isRemoving = false
    @Published private var restoring = true
    @Published private var pendingResumes = 0
    @Published private var tasks: [String: URLSessionTask] = [:]
    private let delegate = LocalDownloadDelegate()
    private var sessions: [URLSession] = []
    private var backgroundCompletions: [String: () -> Void] = [:]
    private var job: Task<Void, Never>?
    private var counts: [String: Int64] = [:]
    private var generation: String
    private var wantsDownload: Bool {
        get { UserDefaults.standard.bool(forKey: Self.activeKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.activeKey) }
    }
    var busy: Bool { restoring || job != nil || !tasks.isEmpty || pendingResumes > 0 || isRemoving }
    init() {
        generation = UserDefaults.standard.string(forKey: Self.generationKey) ?? UUID().uuidString
        UserDefaults.standard.set(generation, forKey: Self.generationKey)
        phase = .paused
        guard LocalModelAvailability.enabled else { restoring = false; return }
        phase = LocalModelManifest.isInstalled() ? .ready : .paused
        sessions = [false, true].map { cellular in
            URLSession(configuration: Self.configuration(cellular: cellular), delegate: delegate, delegateQueue: nil)
        }
        Task { await reconnect() }
    }
    static func configuration(cellular: Bool) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.background(withIdentifier: sessionIDs[cellular ? 1 : 0])
        config.allowsCellularAccess = cellular
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        config.httpMaximumConnectionsPerHost = 2
        return config
    }
    private func file(_ task: URLSessionTask) -> LocalModelFile? {
        guard let name = LocalDownloadPolicy.file(in: task.taskDescription, generation: generation,
                                                 allowed: LocalModelManifest.files.map(\.name)) else { return nil }
        return LocalModelManifest.files.first { $0.name == name }
    }
    private func target(_ file: LocalModelFile) -> URL { LocalModelManifest.directory.appendingPathComponent(file.name) }
    private func part(_ file: LocalModelFile) -> URL { LocalModelManifest.directory.appendingPathComponent(file.name + ".part") }
    private func resume(_ file: LocalModelFile) -> URL { LocalModelManifest.directory.appendingPathComponent(file.name + ".modelscope.resume") }
    private func hasFile(_ file: LocalModelFile) -> Bool {
        [target(file), part(file)].contains { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(file.bytes) }
    }
    private func updateProgress() {
        progress = LocalDownloadPolicy.progress(bytes: counts, expected: Dictionary(uniqueKeysWithValues: LocalModelManifest.files.map { ($0.name, $0.bytes) }))
    }
    private func reconnect() async {
        for session in sessions {
            let restored: [URLSessionTask] = await withCheckedContinuation { continuation in
                session.getAllTasks { continuation.resume(returning: $0) }
            }
            for task in restored {
                guard let file = file(task), wantsDownload, phase != .ready else { task.cancel(); continue }
                guard task.state != .completed, task.state != .canceling else { continue }
                if let prior = tasks[file.name], prior !== task { task.cancel(); continue }
                tasks[file.name] = task
                counts[file.name] = task.countOfBytesReceived
            }
        }
        for file in LocalModelManifest.files where hasFile(file) { counts[file.name] = file.bytes }
        updateProgress()
        restoring = false
        switch LocalDownloadPolicy.recover(installed: LocalModelManifest.isInstalled(), activeTasks: tasks.count,
            completeFiles: LocalModelManifest.files.filter { hasFile($0) }.count, expectedFiles: LocalModelManifest.files.count,
            hasDirectory: FileManager.default.fileExists(atPath: LocalModelManifest.directory.path)) {
        case .installed: phase = .ready
        case .downloading: phase = .downloading
        case .verify: phase = .checking; verifyIfPossible()
        case .paused: wantsDownload = false; phase = .paused
        case .absent: wantsDownload = false; phase = .absent
        }
    }
    func download(cellular: Bool) {
        guard LocalModelAvailability.enabled else { return }
        guard !busy, phase != .ready else { return }
        do {
            var directory = LocalModelManifest.directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            let existing = Dictionary(uniqueKeysWithValues: LocalModelManifest.files.filter { hasFile($0) }.map { ($0.name, $0.bytes) })
            let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            guard available > LocalModelManifest.requiredDownloadSpace(existingSizes: existing) else { throw LocalMiloError.insufficientSpace }
            counts = existing
            wantsDownload = true
            phase = .downloading
            let session = sessions[cellular ? 1 : 0]
            for file in LocalModelManifest.files where !hasFile(file) {
                try? FileManager.default.removeItem(at: target(file))
                try? FileManager.default.removeItem(at: part(file))
                let task: URLSessionDownloadTask
                if let data = try? Data(contentsOf: resume(file)) {
                    task = session.downloadTask(withResumeData: data)
                } else { task = session.downloadTask(with: file.url) }
                task.taskDescription = LocalDownloadPolicy.descriptor(generation: generation, file: file.name)
                task.countOfBytesClientExpectsToReceive = file.bytes
                tasks[file.name] = task
                task.resume()
            }
            updateProgress()
            verifyIfPossible()
        } catch { wantsDownload = false; phase = .failed(error.localizedDescription) }
    }
    fileprivate func updated(_ task: URLSessionDownloadTask, bytes: Int64, expected: Int64) {
        guard let file = file(task), !isRemoving else { return }
        if bytes > file.bytes || expected > file.bytes {
            wantsDownload = false
            phase = .failed(LocalMiloError.invalidFiles.localizedDescription)
            task.cancel()
            return
        }
        counts[file.name] = bytes; updateProgress()
    }
    fileprivate func received(_ task: URLSessionDownloadTask, at location: URL) {
        guard LocalModelAvailability.enabled else { task.cancel(); return }
        guard let file = file(task), !isRemoving else { return }
        do {
            guard let http = task.response as? HTTPURLResponse, [200, 206].contains(http.statusCode),
                  (try location.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(file.bytes) else { throw LocalMiloError.invalidFiles }
            try? FileManager.default.removeItem(at: part(file))
            try FileManager.default.moveItem(at: location, to: part(file))
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: part(file).path)
            counts[file.name] = file.bytes; updateProgress()
        } catch { wantsDownload = false; phase = .failed(error.localizedDescription) }
    }
    fileprivate func completed(_ task: URLSessionTask, error: Error?) {
        guard let file = file(task), !isRemoving else { return }
        // A canceled duplicate must not clear the adopted task or its resume data.
        if let adopted = tasks[file.name], adopted !== task { return }
        tasks.removeValue(forKey: file.name)
        if let error {
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data { try? data.write(to: resume(file), options: .atomic) }
            if (error as? URLError)?.code != .cancelled {
                wantsDownload = false; phase = .failed(error.localizedDescription)
            }
        } else { try? FileManager.default.removeItem(at: resume(file)) }
        if error != nil && tasks.isEmpty && phase == .downloading {
            wantsDownload = false; phase = .paused
        }
        verifyIfPossible()
    }
    private func verifyIfPossible() {
        guard !restoring, tasks.isEmpty, job == nil, !isRemoving, pendingResumes == 0,
              LocalModelManifest.files.allSatisfy({ hasFile($0) }), phase != .ready else { return }
        if case .failed = phase { return }
        if phase == .paused { return }
        phase = .checking
        // Hashing can take longer than the background wake budget. Persisted .part
        // files survive suspension; only the foreground performs installation.
        guard UIApplication.shared.applicationState == .active else { return }
        let current = generation
        job = Task {
            defer {
                job = nil
                // An active transition can arrive before cancellation finishes.
                if phase == .checking && UIApplication.shared.applicationState == .active { verifyIfPossible() }
            }
            do {
                for file in LocalModelManifest.files {
                    try Task.checkCancellation()
                    let url = FileManager.default.fileExists(atPath: part(file).path) ? part(file) : target(file)
                    let verification = Task.detached(priority: .utility) { try LocalModelManifest.verify(url, file: file) }
                    do {
                        try await withTaskCancellationHandler { try await verification.value } onCancel: { verification.cancel() }
                    } catch is CancellationError { throw CancellationError() }
                    catch { try? FileManager.default.removeItem(at: url); throw error }
                    try Task.checkCancellation()
                    guard current == generation else { throw CancellationError() }
                    if url != target(file) {
                        try? FileManager.default.removeItem(at: target(file))
                        try FileManager.default.moveItem(at: url, to: target(file))
                    }
                }
                try Task.checkCancellation()
                try Data(LocalModelManifest.revision.utf8).write(to: LocalModelManifest.directory.appendingPathComponent("ready"), options: .atomic)
                wantsDownload = false; phase = .ready
                LLMSettings.shared.objectWillChange.send()
            } catch is CancellationError {
                if current == generation && phase != .paused { phase = .checking }
            } catch { wantsDownload = false; phase = .failed(error.localizedDescription) }
        }
    }
    func becameActive() { verifyIfPossible() }
    func enteredBackground() { job?.cancel() } // Transfers belong to the OS and continue.
    func pause() {
        wantsDownload = false; phase = .paused; job?.cancel()
        let current = generation
        for task in tasks.values {
            guard let task = task as? URLSessionDownloadTask, let file = file(task) else { continue }
            pendingResumes += 1
            task.cancel(byProducingResumeData: { data in
                Task { @MainActor in
                    if self.generation == current, let data { try? data.write(to: self.resume(file), options: .atomic) }
                    self.pendingResumes -= 1
                }
            })
        }
    }
    func invalidate() {
        try? FileManager.default.removeItem(at: LocalModelManifest.directory.appendingPathComponent("ready"))
        phase = .failed(LocalMiloError.invalidFiles.localizedDescription)
        LLMSettings.shared.objectWillChange.send()
    }
    func remove() async {
        guard !isRemoving, !restoring else { return }
        isRemoving = true
        wantsDownload = false
        generation = UUID().uuidString
        UserDefaults.standard.set(generation, forKey: Self.generationKey)
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        try? FileManager.default.removeItem(at: LocalModelManifest.directory.appendingPathComponent("ready"))
        LLMSettings.shared.objectWillChange.send()
        job?.cancel(); await job?.value
        await LocalInferenceWorker.shared.unload()
        do {
            if FileManager.default.fileExists(atPath: LocalModelManifest.directory.path) { try FileManager.default.removeItem(at: LocalModelManifest.directory) }
            phase = .absent; progress = 0; counts = [:]
        } catch { phase = .failed(error.localizedDescription) }
        isRemoving = false
    }
    func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        guard Self.sessionIDs.contains(identifier) else { completion(); return }
        backgroundCompletions[identifier] = completion
    }
    fileprivate func finishedEvents(identifier: String?) {
        guard let identifier else { return }
        if let completion = backgroundCompletions.removeValue(forKey: identifier) { completion() }
    }
}
