import XCTest
import SwiftData
@testable import AgenticKeepKeep

@MainActor
final class CoachMemoryStoreTests: XCTestCase {
    private func seed(_ context: ModelContext) throws -> [ChatMessage] {
        let user = ChatMessage(role: .user, content: "膝盖旧伤，不能跳跃")
        user.date = Date(timeIntervalSince1970: 1_000)
        let assistant = ChatMessage(role: .assistant, content: "先安排低冲击训练")
        assistant.date = Date(timeIntervalSince1970: 1_001)
        context.insert(user); context.insert(assistant)
        try context.save()
        return [user, assistant]
    }

    private func memory(_ messages: [ChatMessage]) -> CoachMemory {
        let history = CoachHistoryBuilder.turns(messages)
        return CoachMemory(sessionID: messages[0].uuid, coveredCount: history.count,
                           coveredDigest: CoachMemory.digest(history[...]),
                           facts: [CoachMemoryFact(sourceID: messages[0].uuid, quote: messages[0].content)])
    }

    func testMemoryPersistsAcrossContextsWithoutChangingChat() throws {
        let container = try AppModelContainer.inMemory()
        let context = ModelContext(container)
        let messages = try seed(context), value = memory(messages)
        let store = CoachMemoryStore(), token = store.begin()
        try store.save(value, generation: token, context: context)
        let reopened = ModelContext(container)
        let fetched = try reopened.fetch(FetchDescriptor<ChatMessage>())
        XCTAssertEqual(CoachMemoryStore().load(fetched), value)
        XCTAssertEqual(fetched.count, 2)
        XCTAssertEqual(fetched.first(where: { $0.uuid == messages[0].uuid })?.content, messages[0].content)
    }

    func testClearAndNewRequestRejectLateMemoryWrites() throws {
        let container = try AppModelContainer.inMemory()
        let context = ModelContext(container)
        let messages = try seed(context), value = memory(messages)
        let store = CoachMemoryStore(), old = store.begin()
        _ = store.begin()
        XCTAssertThrowsError(try store.save(value, generation: old, context: context))
        let current = store.generation
        try store.clear(context: context)
        XCTAssertThrowsError(try store.save(value, generation: current, context: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 0)
    }

    func testSourceChangesAndFutureVersionInvalidateCache() throws {
        let context = ModelContext(try AppModelContainer.inMemory())
        let messages = try seed(context)
        var value = memory(messages)
        XCTAssertTrue(value.isValid(for: CoachHistoryBuilder.turns(messages)))
        value.version += 1
        XCTAssertFalse(value.isValid(for: CoachHistoryBuilder.turns(messages)))
        value.version = CoachMemory.currentVersion
        messages[0].content = "已纠正原来的描述"
        XCTAssertFalse(value.isValid(for: CoachHistoryBuilder.turns(messages)))
    }

    func testToolOnlyDraftConfirmationRejectionAndReasoningBoundary() {
        let message = ChatMessage(role: .assistant, content: "", pendingPlanJSON: "{\"title\":\"力量计划\"}", reasoningText: "秘密思考，不发送")
        message.date = Date(timeIntervalSince1970: 1_000)
        var turn = CoachHistoryBuilder.turns([message])[0]
        XCTAssertTrue(turn.content.contains("待用户确认"))
        XCTAssertTrue(turn.content.contains("力量计划"))
        XCTAssertFalse(turn.content.contains("秘密思考"))
        message.planAcceptedAt = Date(timeIntervalSince1970: 2_000)
        turn = CoachHistoryBuilder.turns([message])[0]
        XCTAssertTrue(turn.content.contains("已确认"))
        message.planAcceptedAt = nil
        message.planDecisionRaw = "rejected"
        XCTAssertFalse(message.hasPendingPlan)
        XCTAssertTrue(CoachHistoryBuilder.turns([message])[0].content.contains("未采用"))
        message.pendingAdjustmentJSON = "{\"summary\":\"减量\"}"
        message.adjustmentDecisionRaw = "applied"
        XCTAssertFalse(message.hasPendingAdjustment)
        XCTAssertTrue(CoachHistoryBuilder.turns([message])[0].content.contains("已确认应用"))
    }

    func testCurrentPlanStateFollowsDatabaseEditsAndBoundsLargePlan() throws {
        let context = ModelContext(try AppModelContainer.inMemory())
        let old = Plan(title: "旧计划", goal: .general, weeks: 4); old.isActive = false
        let current = Plan(title: "当前计划", goal: .general, weeks: 4)
        context.insert(old); context.insert(current)
        for index in 0..<100 {
            let day = PlanDay(date: Date().addingTimeInterval(Double(index) * 86_400), title: "训练\(index)", order: index)
            day.plan = current; context.insert(day)
            let exercise = PlanExercise(name: index == 90 ? "卧推" : "划船", setsText: "4×8", targetWeightKg: Double(index), order: 0)
            exercise.day = day; context.insert(exercise)
        }
        try context.save()
        let value = try CoachPlanContext.build(context: context, query: "卧推怎么安排")
        XCTAssertTrue(value.contains("当前计划"))
        XCTAssertTrue(value.contains("卧推"))
        XCTAssertTrue(value.contains("90.0kg"))
        XCTAssertTrue(value.contains("省略"))
        XCTAssertLessThanOrEqual(value.utf8.count, 2_000)
        current.title = "调整后的计划"
        XCTAssertTrue(try CoachPlanContext.build(context: context, query: "今天").contains("调整后的计划"))
        current.isActive = false
        XCTAssertTrue(try CoachPlanContext.build(context: context, query: "今天").contains("没有进行中"))
    }

    func testLegacyEmptyRepliesDoNotBecomeEmptyProviderMessages() throws {
        let context = ModelContext(try AppModelContainer.inMemory())
        let empty = ChatMessage(role: .assistant, content: "")
        empty.date = Date(timeIntervalSince1970: 0)
        context.insert(empty)
        let messages = try seed(context)
        let all = [empty] + messages
        let turns = CoachHistoryBuilder.turns(all)
        XCTAssertEqual(turns.count, 2)
        let store = CoachMemoryStore()
        try store.save(memory(messages), generation: store.begin(), context: context)
        XCTAssertNotNil(store.load(all))
        XCTAssertNil(empty.coachMemoryJSON)
    }

    func testWindowConfigurationIsIsolatedByEndpointAndModel() throws {
        let suite = "CoachWindowTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LLMSettings(defaults: defaults)
        settings.preset = .custom; settings.customBaseURL = "https://a.invalid/v1"; settings.modelName = "a"
        XCTAssertEqual(settings.coachContextWindow, 131_072)
        let previous = ServiceRuntime.shared.configuration
        defer { ServiceRuntime.shared.configuration = previous }
        ServiceRuntime.shared.configuration = ServiceConfiguration(model: "service", contextWindow: 32_768, maxOutput: 4096, searchEnabled: false, supportContact: "admin")
        XCTAssertEqual(try settings.coachPolicy.inputLimit(), 27_648)
        settings.coachContextWindow = 32_768
        settings.modelName = "b"
        XCTAssertEqual(settings.coachContextWindow, 131_072)
        settings.modelName = "a"
        XCTAssertEqual(settings.coachContextWindow, 32_768)
        settings.customBaseURL = "https://b.invalid/v1"
        XCTAssertEqual(settings.coachContextWindow, 131_072)
    }
}
