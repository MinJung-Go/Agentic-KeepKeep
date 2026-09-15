import Foundation
import SwiftData
import Combine

@MainActor
final class ExerciseTutorialStore: ObservableObject {
    static let shared = ExerciseTutorialStore()
    @Published private(set) var running: Set<String> = []
    @Published private(set) var activities: [String: [CoachToolActivity]] = [:]
    @Published private(set) var error: String?
    private let configuration: () throws -> LLMClientConfig?
    private let fetch: (TutorialExercise, LLMClientConfig) async throws -> [ExerciseTutorial]
    private let read: (URL, LLMClientConfig) async throws -> CoachToolResult
    private var batchGeneration = 0
    init(configuration: @escaping () throws -> LLMClientConfig? = {
        let settings = LLMSettings.shared
        guard settings.webSearchEnabled, settings.supportsWebSearch, settings.isConfigured else { return nil }
        return try settings.makeRecordingClient().config
    }, fetch: @escaping (TutorialExercise, LLMClientConfig) async throws -> [ExerciseTutorial] = { exercise, config in
        let body = try JSONSerialization.data(withJSONObject: [
            "search_query": exercise.query, "search_engine": "search_std",
            "search_intent": false, "count": 10, "search_recency_filter": "noLimit"
        ])
        let data = try await GLMWebSearch(config: config).fetch(body: body)
        return try ExerciseTutorial.decode(data, exercise: exercise)
    }, read: @escaping (URL, LLMClientConfig) async throws -> CoachToolResult = { url, config in
        try await GLMWebReader(config: config).read(url: url)
    }) {
        self.read = read
        self.configuration = configuration
        self.fetch = fetch
    }
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Serialize automatic enrichment; every batch has a finite paid-request budget.
    static let batchLimit = 12
    static let cacheLifetime: TimeInterval = 30 * 86400

    static func entries(_ entry: ExerciseTutorialCache?) -> [ExerciseTutorial] {
        guard let entry else { return [] }
        let rejected = (try? JSONDecoder().decode([String].self, from: Data(entry.rejectedURLsJSON.utf8))) ?? []
        let items = (try? JSONDecoder().decode([ExerciseTutorial].self, from: Data(entry.resultsJSON.utf8))) ?? []
        return items.filter { !rejected.contains($0.id) && ExerciseTutorial.platform(for: $0.url) != nil }
            .sorted { a, b in a.id == entry.selectedURL && b.id != entry.selectedURL }
    }
    static func find(_ key: String, context: ModelContext) throws -> ExerciseTutorialCache? {
        var query = FetchDescriptor<ExerciseTutorialCache>(predicate: #Predicate { $0.key == key })
        query.fetchLimit = 1
        return try context.fetch(query).first
    }
    static func needsRefresh(_ entry: ExerciseTutorialCache?, now: Date = .now) -> Bool {
        guard let entry else { return true }
        if entry.status == "stopped" { return false }
        let age = now.timeIntervalSince(entry.checkedAt)
        return age > (entry.status == "failed" ? 3600 : cacheLifetime)
    }

    func enrich(names: [String], context: ModelContext, retryUnresolved: Bool = false) async {
        let generation = batchGeneration
        var budget = Self.batchLimit
        for name in Set(names.compactMap { TutorialExercise.resolve($0)?.name }).sorted() {
            guard !Task.isCancelled, generation == batchGeneration, budget > 0 else { break }
            guard (try? configuration()) != nil else { break }
            guard let exercise = TutorialExercise.resolve(name) else { continue }
            do {
                let entry = try Self.find(exercise.name, context: context)
                guard Self.needsRefresh(entry) || (retryUnresolved && Self.entries(entry).isEmpty) else { continue }
            } catch { self.error = "无法读取教学缓存"; break }
            budget -= 1
            await load(name: name, context: context)
        }
    }

    func load(name: String, context: ModelContext) async {
        guard let exercise = TutorialExercise.resolve(name) else { return }
        if let task = tasks[exercise.name] { await task.value; return }
        guard let config = try? configuration() else { return }
        error = nil
        let task = Task { @MainActor in
            let storageContext = ModelContext(context.container)
            running.insert(exercise.name)
            defer { running.remove(exercise.name) }
            activities[exercise.name] = []
            var activity = CoachToolActivity(title: "搜索\(exercise.name)教学")
            var started = ContinuousClock.now
            update(activity, key: exercise.name)
            do {
                var values = try await fetch(exercise, config)
                activity.finish(.completed, since: started)
                update(activity, key: exercise.name)
                try Task.checkCancellation()
                guard let current = try configuration(), current == config else { throw CancellationError() }
                // Read at most two returned video pages. Failure retains honest search-only provenance.
                for index in values.indices.prefix(2) {
                    try Task.checkCancellation()
                    guard let current = try configuration(), current == config else { throw CancellationError() }
                    activity = CoachToolActivity(title: "阅读教学来源 \(index + 1)")
                    started = .now
                    update(activity, key: exercise.name)
                    do {
                        let page = try await read(values[index].url, config)
                        try Task.checkCancellation()
                        activity.finish(page.failed ? .failed : .completed, since: started)
                        if !page.failed {
                            values[index].reason += " 已读取公开页面文字，未解析视频画面。"
                        }
                    } catch {
                        try Task.checkCancellation()
                        activity.finish(.failed, since: started)
                    }
                    update(activity, key: exercise.name)
                }
                try Task.checkCancellation()
                guard let current = try configuration(), current == config else { throw CancellationError() }
                let entry = try Self.find(exercise.name, context: storageContext) ?? ExerciseTutorialCache(key: exercise.name)
                if entry.modelContext == nil { storageContext.insert(entry) }
                entry.resultsJSON = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
                entry.status = values.isEmpty ? "empty" : "ready"
                entry.checkedAt = .now
                entry.activityJSON = activityJSON(key: exercise.name)
                try storageContext.save()
            } catch {
                storageContext.rollback()
                let cancelled = Task.isCancelled || error is CancellationError
                if activity.status == .running {
                    activity.finish(cancelled ? .cancelled : .failed, since: started)
                    update(activity, key: exercise.name)
                }
                do {
                    let entry = try Self.find(exercise.name, context: storageContext) ?? ExerciseTutorialCache(key: exercise.name)
                    if entry.modelContext == nil { storageContext.insert(entry) }
                    entry.status = cancelled ? "stopped" : "failed"
                    entry.checkedAt = .now
                    entry.activityJSON = activityJSON(key: exercise.name)
                    try storageContext.save()
                } catch { self.error = "教学状态保存失败，请稍后重试" }
                if !cancelled { self.error = "教学补充未完成，请检查网络和模型配置后重试" }
            }
        }
        tasks[exercise.name] = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        tasks[exercise.name] = nil
    }

    private func update(_ activity: CoachToolActivity, key: String) {
        var values = activities[key] ?? []
        if let index = values.firstIndex(where: { $0.id == activity.id }) { values[index] = activity }
        else { values.append(activity) }
        activities[key] = values
    }
    private func activityJSON(key: String) -> String? {
        (try? JSONEncoder().encode(activities[key] ?? [])).map { String(decoding: $0, as: UTF8.self) }
    }

    func stop(name: String) { if let key = TutorialExercise.resolve(name)?.name { tasks[key]?.cancel() } }
    func stopAll() { batchGeneration += 1; for task in tasks.values { task.cancel() } }

    static func choose(_ video: ExerciseTutorial, entry: ExerciseTutorialCache, context: ModelContext) throws {
        guard entries(entry).contains(where: { $0.id == video.id }) else { return }
        let old = entry.selectedURL
        entry.selectedURL = video.id
        do { try context.save() } catch { entry.selectedURL = old; throw error }
    }
    static func reject(_ video: ExerciseTutorial, entry: ExerciseTutorialCache, context: ModelContext) throws {
        let old = entry.rejectedURLsJSON
        var rejected = (try? JSONDecoder().decode([String].self, from: Data(old.utf8))) ?? []
        if !rejected.contains(video.id) { rejected.append(video.id) }
        entry.rejectedURLsJSON = String(decoding: try JSONEncoder().encode(Array(rejected.suffix(100))), as: UTF8.self)
        do { try context.save() } catch { entry.rejectedURLsJSON = old; throw error }
    }
}
