import XCTest
@testable import AgenticKeepKeep

final class RecordJSONRecoveryTests: XCTestCase {
    private let valid = #"{"records":[{"type":"meal","meal":{"items":[{"name":"米饭"}]}}]}"#

    func testSchemaErrorKeepsRecordsPathWithoutNestedErrorWrapper() async {
        let client = MockLLMClient(responses: [.text(#"{"records":"wrong"}"#)])
        do {
            _ = try await ParserAgent(client: client).parse("午餐")
            XCTFail("Wrong records type must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("records"))
            XCTAssertFalse(error.localizedDescription.contains("invalidJSON("))
            XCTAssertFalse(error.localizedDescription.contains("wrong"))
        }
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertNil(client.requests.first?.thinkingEnabled)
    }

    func testLocalSchemaFailureRetriesOnceWithOriginalImageAndText() async throws {
        let client = MockLLMClient(responses: [.text(#"{"records":"wrong"}"#), .text(valid)])
        client.config.baseURL = "local://milo"
        let records = try await ParserAgent(client: client).parse("午餐，不知道分量", imageBase64JPEG: "fixture-photo")
        XCTAssertEqual(records.first?.meal?.items.first?.name, "米饭")
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(client.requests.last?.messages.last?.imagesBase64JPEG, ["fixture-photo"])
        XCTAssertEqual(client.requests.last?.messages.last?.content, "午餐，不知道分量")
        XCTAssertEqual(client.requests.last?.temperature, 0)
        XCTAssertFalse(client.requests.last?.messages.contains { $0.content.contains("wrong") } ?? true)
    }

    func testTextRetryPreservesHistoryAndOriginalInput() async throws {
        let result = #"{"records":[{"type":"workout","workout":{"exercises":[{"name":"深蹲","weightKg":100,"sets":6,"reps":5}]}}]}"#
        let client = MockLLMClient(responses: [.text("{}"), .text(result)])
        client.config.baseURL = "local://milo"
        let records = try await ParserAgent(client: client).parse("再加一组", history: [
            CoachTurn(role: .user, content: "深蹲100kg，5组每组5次"),
            CoachTurn(role: .assistant, content: "深蹲100kg 5×5")
        ])
        XCTAssertEqual(records.first?.workout?.exercises.first?.sets, 6)
        XCTAssertEqual(client.requests.count, 2)
        let first = try XCTUnwrap(client.requests.first)
        let second = try XCTUnwrap(client.requests.last)
        XCTAssertEqual(first.messages.dropFirst().map(\.content), second.messages.dropFirst().map(\.content))
        XCTAssertEqual(second.messages.last?.content, "再加一组")
        XCTAssertTrue(second.messages.allSatisfy { $0.imagesBase64JPEG.isEmpty })
        XCTAssertEqual(second.thinkingEnabled, false)
    }

    func testValidLocalTextDoesNotRetry() async throws {
        let client = MockLLMClient(responses: [.text(valid)])
        client.config.baseURL = "local://milo"
        _ = try await ParserAgent(client: client).parse("午餐吃了米饭")
        XCTAssertEqual(client.requests.count, 1)
    }

    func testLocalNetworkErrorDoesNotRetry() async {
        let client = MockLLMClient(error: LLMError.network("fixture"))
        client.config.baseURL = "local://milo"
        do { _ = try await ParserAgent(client: client).parse("午餐"); XCTFail() }
        catch { XCTAssertEqual(error as? LLMError, .network("fixture")) }
        XCTAssertEqual(client.requests.count, 1)
    }

    func testArrayEmptyResultHasSameMeaningAsEmptyRecords() async {
        let client = MockLLMClient(responses: [.text("[]"), .text(valid)])
        client.config.baseURL = "local://milo"
        do { _ = try await ParserAgent(client: client).parse("无法识别"); XCTFail() }
        catch { XCTAssertEqual(error as? AgentError, .emptyResult) }
        XCTAssertEqual(client.requests.count, 1)
    }

    func testLocalTransportJSONFailureCanRecover() async throws {
        let client = MockLLMClient(error: LocalMiloError.malformedTool)
        client.config.baseURL = "local://milo"
        client.enqueue(.text(valid))
        let result = try await ParserAgent(client: client).parse("午餐")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(client.requests.count, 2)
    }

    func testLocalRetryIsBounded() async {
        let client = MockLLMClient(responses: [.text("{}"), .text("{}"), .text(valid)])
        client.config.baseURL = "local://milo"
        do { _ = try await ParserAgent(client: client).parse("午餐"); XCTFail() }
        catch { XCTAssertTrue(error is AgentError) }
        XCTAssertEqual(client.requests.count, 2)
    }

    func testMemoryAndCancellationDoNotRetry() async {
        for error: Error in [LocalMiloError.memoryPressure, CancellationError()] {
            let client = MockLLMClient(error: error)
            client.config.baseURL = "local://milo"
            client.enqueue(.text(valid))
            do { _ = try await ParserAgent(client: client).parse("午餐"); XCTFail() }
            catch { }
            XCTAssertEqual(client.requests.count, 1)
        }
    }

    func testLocalEmptyRecordsDoNotRetry() async {
        let client = MockLLMClient(responses: [.text(#"{"records":[]}"#), .text(valid)])
        client.config.baseURL = "local://milo"
        do { _ = try await ParserAgent(client: client).parse("图片看不清"); XCTFail() }
        catch { XCTAssertEqual(error as? AgentError, .emptyResult) }
        XCTAssertEqual(client.requests.count, 1)
    }
}
