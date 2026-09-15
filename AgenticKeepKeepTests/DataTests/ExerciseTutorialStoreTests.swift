import XCTest
import SwiftData
@testable import AgenticKeepKeep

@MainActor
final class ExerciseTutorialStoreTests: XCTestCase {
    private let config = LLMClientConfig(baseURL: "https://open.bigmodel.cn/api/paas/v4", apiKey: "fixture", model: "fixture")
    private func fixture() throws -> ModelContext { ModelContext(try AppModelContainer.inMemory()) }
    private func video(_ id: String) -> ExerciseTutorial {
        ExerciseTutorial(title: "哑铃卧推教学", url: URL(string: "https://www.bilibili.com/video/BV\(id)")!, platform: "哔哩哔哩", reason: "fixture")
    }
    func testChoiceAndRejectionPersistWithoutChangingPlan() async throws {
        let context = try fixture()
        let exercise = PlanExercise(name: "哑铃卧推", setsText: "3×10")
        context.insert(exercise)
        let entry = ExerciseTutorialCache(key: "哑铃卧推")
        entry.resultsJSON = String(decoding: try JSONEncoder().encode([video("1"), video("2")]), as: UTF8.self)
        context.insert(entry); try context.save()
        try ExerciseTutorialStore.choose(video("2"), entry: entry, context: context)
        try ExerciseTutorialStore.reject(video("1"), entry: entry, context: context)
        let reload = try XCTUnwrap(ExerciseTutorialStore.find(entry.key, context: ModelContext(context.container)))
        XCTAssertEqual(ExerciseTutorialStore.entries(reload).map(\.id), [video("2").id])
        XCTAssertEqual(exercise.name, "哑铃卧推")
        XCTAssertEqual(exercise.setsText, "3×10")
    }
    func testDisabledAndUnknownExerciseNeverMakeRequests() async throws {
        let context = try fixture()
        let disabled = ExerciseTutorialStore(configuration: { nil }, fetch: { _, _ in XCTFail(); return [] })
        await disabled.load(name: "哑铃卧推", context: context)
        let unknown = ExerciseTutorialStore(configuration: { self.config }, fetch: { _, _ in XCTFail(); return [] })
        await unknown.load(name: "私人备注 体重70kg", context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ExerciseTutorialCache>()), 0)
    }
    func testEnrichmentReusesCanonicalCacheAndHasRequestBudget() async throws {
        let context = try fixture()
        var calls = 0
        let store = ExerciseTutorialStore(configuration: { self.config }, fetch: { _, _ in calls += 1; return [] })
        await store.enrich(names: ["哑铃卧推", "平板哑铃卧推", "哑铃卧推"], context: context)
        XCTAssertEqual(calls, 1)
        await store.enrich(names: ["哑铃卧推"], context: context)
        XCTAssertEqual(calls, 1)
        calls = 0
        await store.enrich(names: ["哑铃卧推", "平板哑铃卧推"], context: context, retryUnresolved: true)
        XCTAssertEqual(calls, 1)
        calls = 0
        await store.enrich(names: TutorialExercise.names, context: context)
        XCTAssertLessThanOrEqual(calls, ExerciseTutorialStore.batchLimit)
    }
    func testFailedRefreshKeepsExistingVideoAndCourse() async throws {
        let context = try fixture()
        let entry = ExerciseTutorialCache(key: "哑铃卧推")
        entry.resultsJSON = String(decoding: try JSONEncoder().encode([video("1")]), as: UTF8.self)
        context.insert(entry); try context.save()
        let store = ExerciseTutorialStore(configuration: { self.config }, fetch: { _, _ in throw LLMError.emptyResponse })
        await store.load(name: "哑铃卧推", context: context)
        let reloaded = try XCTUnwrap(ExerciseTutorialStore.find("哑铃卧推", context: ModelContext(context.container)))
        XCTAssertEqual(reloaded.status, "failed")
        XCTAssertEqual(ExerciseTutorialStore.entries(reloaded).count, 1)
        XCTAssertFalse(ExerciseTutorialStore.needsRefresh(reloaded))
    }
    func testStopDiscardsLateResultAndPreservesRetry() async throws {
        let context = try fixture()
        var continuation: CheckedContinuation<[ExerciseTutorial], Never>?
        let store = ExerciseTutorialStore(configuration: { self.config }, fetch: { _, _ in
            await withCheckedContinuation { continuation = $0 }
        })
        let task = Task { await store.load(name: "哑铃卧推", context: context) }
        while continuation == nil { await Task.yield() }
        store.stopAll()
        continuation?.resume(returning: [video("1")])
        await task.value
        let entry = try XCTUnwrap(ExerciseTutorialStore.find("哑铃卧推", context: context))
        XCTAssertEqual(entry.status, "stopped")
        XCTAssertTrue(ExerciseTutorialStore.entries(entry).isEmpty)
        XCTAssertFalse(ExerciseTutorialStore.needsRefresh(entry))
    }
    func testSearchThenReaderEventsAreOrderedAndBodiesAreNotStored() async throws {
        let context = try fixture()
        var reads = 0
        let store = ExerciseTutorialStore(configuration: { self.config }, fetch: { _, _ in
            [self.video("1"), self.video("2"), self.video("3")]
        }, read: { _, _ in
            reads += 1
            return CoachToolResult(content: "secret fixture webpage body")
        })
        await store.load(name: "哑铃卧推", context: context)
        XCTAssertEqual(reads, 2)
        let entry = try XCTUnwrap(ExerciseTutorialStore.find("哑铃卧推", context: context))
        XCTAssertEqual(CoachToolActivity.decode(entry.activityJSON).map(\.title), ["搜索哑铃卧推教学", "阅读教学来源 1", "阅读教学来源 2"])
        XCTAssertFalse(entry.resultsJSON.contains("secret fixture"))
        XCTAssertFalse(entry.activityJSON?.contains("secret fixture") ?? true)
        XCTAssertEqual(ExerciseTutorialStore.entries(entry).count, 3)
    }

    func testReaderFailureKeepsSearchProvenanceAndAvailableLink() async throws {
        let context = try fixture()
        let store = ExerciseTutorialStore(configuration: { self.config }, fetch: { _, _ in [self.video("1")] },
            read: { _, _ in throw LLMError.emptyResponse })
        await store.load(name: "哑铃卧推", context: context)
        let entry = try XCTUnwrap(ExerciseTutorialStore.find("哑铃卧推", context: context))
        XCTAssertEqual(ExerciseTutorialStore.entries(entry).count, 1)
        XCTAssertEqual(CoachToolActivity.decode(entry.activityJSON).last?.status, .failed)
        XCTAssertFalse(entry.resultsJSON.contains("已读取"))
    }

    func testDisablingDuringRequestDiscardsLateResult() async throws {
        let context = try fixture()
        var enabled = true
        let store = ExerciseTutorialStore(configuration: { enabled ? self.config : nil }, fetch: { _, _ in
            enabled = false
            return [self.video("1")]
        })
        await store.load(name: "哑铃卧推", context: context)
        let entry = try XCTUnwrap(ExerciseTutorialStore.find("哑铃卧推", context: context))
        XCTAssertEqual(entry.status, "stopped")
        XCTAssertTrue(ExerciseTutorialStore.entries(entry).isEmpty)
    }
}
