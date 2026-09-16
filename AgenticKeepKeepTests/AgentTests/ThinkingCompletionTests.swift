import XCTest
@testable import AgenticKeepKeep

@MainActor
final class ThinkingCompletionTests: XCTestCase {
    func testThinkingIsCompletedWhileBodyIsConsumed() async throws {
        var activities: [CoachToolActivity] = []
        let tools = CoachTools(onActivity: { activities.append($0) }) { _ in
            XCTFail("No tool should execute")
            return CoachToolResult(content: "")
        }
        let client = CoachToolClient(base: PhasedClient(), tools: tools, policy: CoachContextPolicy())
        var sawBody = false
        for try await event in client.stream(LLMRequest(messages: [.user("你好")])) {
            if case .text(let chunk) = event {
                let thinking = activities.filter { $0.kind == "thinking" }
                if !chunk.isEmpty {
                    sawBody = true
                    XCTAssertEqual(thinking.last?.status, .completed)
                    XCTAssertEqual(thinking.last?.reasoning, "先查看状态")
                }
            }
        }
        XCTAssertTrue(sawBody)
        XCTAssertEqual(activities.filter { $0.kind == "thinking" && $0.status == .completed }.count, 1)
    }
}

private struct PhasedClient: LLMClient {
    let config = LLMClientConfig(baseURL: "https://fixture.invalid", apiKey: "fixture", model: "fixture")
    func complete(_ request: LLMRequest) async throws -> LLMResponse { .text("正文") }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.reasoning("先查看状态"))
            continuation.yield(.text(""))
            continuation.yield(.text("正文"))
            continuation.yield(.text("继续"))
            continuation.finish()
        }
    }
}
