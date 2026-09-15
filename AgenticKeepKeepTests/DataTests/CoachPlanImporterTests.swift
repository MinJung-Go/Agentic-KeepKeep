import XCTest
import SwiftData
@testable import AgenticKeepKeep

@MainActor
final class CoachPlanImporterTests: XCTestCase {
    private let json = """
    {"title":"力量计划","goal":"general","weeks":4,"days":[{"dayOffset":1,"title":"上肢","exercises":[{"name":"卧推","setsText":"4×8","targetWeightKg":60}]}]}
    """

    func testConfirmationRetainsToolOnlyReplyAcrossContextsAndCannotImportTwice() throws {
        let container = try AppModelContainer.inMemory()
        let context = ModelContext(container)
        let message = ChatMessage(role: .assistant, content: "", pendingPlanJSON: json, pendingPlanTitle: "力量计划")
        context.insert(message)
        try context.save()
        let draft = try JSONDecoder().decode(PlanDraft.self, from: Data(json.utf8))
        let now = Date(timeIntervalSince1970: 1_789_344_000)
        let plan = try XCTUnwrap(CoachPlanImporter.accept(draft, message: message, context: context, now: now))
        XCTAssertEqual(plan.title, "力量计划")

        let reopened = ModelContext(container)
        let saved = try XCTUnwrap(reopened.fetch(FetchDescriptor<ChatMessage>()).first)
        XCTAssertEqual(saved.content, "")
        XCTAssertEqual(saved.pendingPlanJSON, json)
        XCTAssertEqual(saved.pendingPlanTitle, "力量计划")
        XCTAssertEqual(saved.planAcceptedAt, now)
        XCTAssertFalse(saved.hasPendingPlan)
        XCTAssertNil(try CoachPlanImporter.accept(draft, message: saved, context: reopened))
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<Plan>()), 1)
        let day = try XCTUnwrap(reopened.fetch(FetchDescriptor<PlanDay>()).first)
        XCTAssertEqual(day.date, Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)))
        let exercise = try XCTUnwrap(reopened.fetch(FetchDescriptor<PlanExercise>()).first)
        XCTAssertEqual(exercise.name, "卧推")
        XCTAssertEqual(exercise.targetWeightKg, 60)
    }

    func testNewPlanReplacesActivePlanWithoutErasingPreviousReceipt() throws {
        let container = try AppModelContainer.inMemory()
        let context = ModelContext(container)
        let draft = try JSONDecoder().decode(PlanDraft.self, from: Data(json.utf8))
        let first = ChatMessage(role: .assistant, content: "", pendingPlanJSON: json)
        let second = ChatMessage(role: .assistant, content: "", pendingPlanJSON: json)
        context.insert(first)
        context.insert(second)
        let previous = try XCTUnwrap(CoachPlanImporter.accept(draft, message: first, context: context))
        let current = try XCTUnwrap(CoachPlanImporter.accept(draft, message: second, context: context))
        XCTAssertFalse(previous.isActive)
        XCTAssertTrue(current.isActive)
        XCTAssertEqual(first.pendingPlanJSON, json)
        XCTAssertNotNil(first.planAcceptedAt)
        XCTAssertNotNil(second.planAcceptedAt)
    }
}
