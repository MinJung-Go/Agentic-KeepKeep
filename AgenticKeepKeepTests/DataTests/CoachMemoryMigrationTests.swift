import XCTest
import SwiftData
@testable import AgenticKeepKeep

/// The shipped ChatMessage shape before context memory was introduced.
private enum LegacyCoachSchema {
    @Model final class ChatMessage {
        var uuid: UUID = UUID()
        var roleRaw: String = "user"
        var content: String = ""
        var date: Date = Date()
        var pendingPlanJSON: String?
        var pendingPlanTitle: String?
        var planAcceptedAt: Date? = nil
        var pendingAdjustmentJSON: String?
        var reasoningText: String?
        init(content: String) { self.content = content }
    }
}

@MainActor
final class CoachMemoryMigrationTests: XCTestCase {
    func testExistingChatStoreMigratesWithoutLosingMessagesOrReceipts() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chat.store")
        let id = UUID()
        try autoreleasepool {
            let schema = Schema([LegacyCoachSchema.ChatMessage.self])
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
            let context = ModelContext(container)
            let message = LegacyCoachSchema.ChatMessage(content: "旧版聊天")
            message.uuid = id
            message.pendingPlanJSON = "{\"title\":\"已确认计划\"}"
            message.planAcceptedAt = Date(timeIntervalSince1970: 1_000)
            context.insert(message)
            try context.save()
        }
        let schema = Schema([ChatMessage.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
        let context = ModelContext(container)
        let message = try XCTUnwrap(context.fetch(FetchDescriptor<ChatMessage>()).first)
        XCTAssertEqual(message.uuid, id)
        XCTAssertEqual(message.content, "旧版聊天")
        XCTAssertNotNil(message.planAcceptedAt)
        XCTAssertTrue(message.pendingPlanJSON?.contains("已确认计划") == true)
        XCTAssertNil(message.coachMemoryJSON)
        XCTAssertNil(message.planDecisionRaw)
    }
}
