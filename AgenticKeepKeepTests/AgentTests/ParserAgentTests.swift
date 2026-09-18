import XCTest
@testable import AgenticKeepKeep

final class ParserAgentTests: XCTestCase {

    func testPhotoOnlyRequestCanProduceTrainingProposal() async throws {
        let json = #"{"records":[{"type":"workout","workout":{"exercises":[{"name":"深蹲","weightKg":100,"sets":5,"reps":5}]}}]}"#
        let client = MockLLMClient(responses: [.text(json)])
        let records = try await ParserAgent(client: client).parse("", imageBase64JPEG: "fixture-image")
        XCTAssertEqual(client.lastRequest?.messages.last?.imagesBase64JPEG, ["fixture-image"])
        XCTAssertEqual(records.first?.workout?.exercises.first?.weightKg, 100)
        XCTAssertEqual(records.first?.kind, .workout)
    }

    func testParsesWorkoutRecord() async throws {
        let json = """
        {"records":[{"type":"workout","workout":{"title":"腿日","exercises":[{"name":"深蹲","weightKg":100,"reps":5,"sets":5}],"rpe":8}}]}
        """
        let agent = ParserAgent(client: MockLLMClient(responses: [.text(json)]))

        let records = try await agent.parse("深蹲100kg 5×5，有点累")

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].kind, .workout)
        let exercise = try XCTUnwrap(records[0].workout?.exercises.first)
        XCTAssertEqual(exercise.name, "深蹲")
        XCTAssertEqual(exercise.weightKg, 100)
        XCTAssertEqual(exercise.reps, 5)
        XCTAssertEqual(exercise.sets, 5)
        XCTAssertEqual(records[0].workout?.rpe, 8)
    }

    func testParsesMealRecord() async throws {
        let json = """
        {"records":[{"type":"meal","meal":{"mealType":"lunch","items":[{"name":"牛肉面","amountText":"1 碗","calories":650,"proteinG":30,"carbsG":85,"fatG":18}]}}]}
        """
        let agent = ParserAgent(client: MockLLMClient(responses: [.text(json)]))

        let records = try await agent.parse("中午吃了牛肉面")

        XCTAssertEqual(records[0].kind, .meal)
        let food = try XCTUnwrap(records[0].meal?.items.first)
        XCTAssertEqual(food.name, "牛肉面")
        XCTAssertEqual(food.calories, 650)
        XCTAssertEqual(food.proteinG, 30)
        XCTAssertEqual(records[0].meal?.mealType, "lunch")
    }

    func testParsesMultipleRecordsFromOneSentence() async throws {
        let json = """
        {"records":[
          {"type":"workout","workout":{"title":"深蹲日","exercises":[{"name":"深蹲","weightKg":100,"reps":5,"sets":5}]}},
          {"type":"meal","meal":{"mealType":"dinner","items":[{"name":"鸡胸肉","calories":300}]}}
        ]}
        """
        let agent = ParserAgent(client: MockLLMClient(responses: [.text(json)]))

        let records = try await agent.parse("深蹲5×5，晚上吃了鸡胸肉")

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].kind, .workout)
        XCTAssertEqual(records[1].kind, .meal)
    }

    func testParsesMetricRecord() async throws {
        let json = #"{"records":[{"type":"metric","metric":{"kind":"weight","value":74.5}}]}"#
        let agent = ParserAgent(client: MockLLMClient(responses: [.text(json)]))

        let records = try await agent.parse("体重74.5")

        XCTAssertEqual(records[0].kind, .metric)
        XCTAssertEqual(records[0].metric?.kind, "weight")
        XCTAssertEqual(records[0].metric?.value, 74.5)
    }

    func testParsesNoteRecord() async throws {
        let json = #"{"records":[{"type":"note","note":"昨晚只睡了5小时"}]}"#
        let agent = ParserAgent(client: MockLLMClient(responses: [.text(json)]))

        let records = try await agent.parse("昨晚只睡了5小时")

        XCTAssertEqual(records[0].kind, .note)
        XCTAssertEqual(records[0].note, "昨晚只睡了5小时")
    }

    // MARK: - 容错

    func testToleratesCodeFences() async throws {
        let content = """
        ```json
        {"records":[{"type":"workout","workout":{"exercises":[{"name":"卧推","weightKg":80,"reps":8,"sets":5}]}}]}
        ```
        """
        let agent = ParserAgent(client: MockLLMClient(responses: [.text(content)]))

        let records = try await agent.parse("卧推80做组")

        XCTAssertEqual(records[0].workout?.exercises.first?.weightKg, 80)
    }

    func testToleratesStringNumbers() async throws {
        let json = """
        {"records":[{"type":"workout","workout":{"exercises":[{"name":"硬拉","weightKg":"120","reps":"3","sets":"5"}]}}]}
        """
        let agent = ParserAgent(client: MockLLMClient(responses: [.text(json)]))

        let records = try await agent.parse("硬拉120 3×5")

        let exercise = try XCTUnwrap(records[0].workout?.exercises.first)
        XCTAssertEqual(exercise.weightKg, 120)
        XCTAssertEqual(exercise.reps, 3)
        XCTAssertEqual(exercise.sets, 5)
    }

    func testToleratesSnakeCaseAndAlternateKeys() async throws {
        let json = """
        {"records":[{"kind":"workout","workout":{"exercises":[{"name":"划船","weight":60,"reps":10}]}}]}
        """
        let agent = ParserAgent(client: MockLLMClient(responses: [.text(json)]))

        let records = try await agent.parse("划船60kg 10次")

        XCTAssertEqual(records[0].kind, .workout)
        XCTAssertEqual(records[0].workout?.exercises.first?.weightKg, 60)
    }

    func testToleratesBareArrayResponse() async throws {
        let json = #"[{"type":"note","note":"今天状态不好"}]"#
        let agent = ParserAgent(client: MockLLMClient(responses: [.text(json)]))

        let records = try await agent.parse("今天状态不好")

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].kind, .note)
    }

    func testInfersKindFromPayloadWhenTypeMissing() async throws {
        let json = #"{"records":[{"workout":{"exercises":[{"name":"深蹲","weightKg":100,"reps":5}]}}]}"#
        let agent = ParserAgent(client: MockLLMClient(responses: [.text(json)]))

        let records = try await agent.parse("深蹲100 5次")

        XCTAssertEqual(records[0].kind, .workout)
    }

    // MARK: - 错误路径

    func testThrowsOnNonJSONContent() async {
        let agent = ParserAgent(client: MockLLMClient(responses: [.text("抱歉，我不明白你的意思。")]))

        do {
            _ = try await agent.parse("随便说点什么")
            XCTFail("应当抛出解析错误")
        } catch {
            XCTAssertTrue(error is AgentError)
        }
    }

    func testThrowsOnEmptyResponse() async {
        let agent = ParserAgent(client: MockLLMClient(responses: [.text("")]))

        do {
            _ = try await agent.parse("深蹲100kg")
            XCTFail("应当抛出空响应错误")
        } catch let error as AgentError {
            XCTAssertEqual(error, .emptyResponse)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testThrowsOnEmptyRecords() async {
        let agent = ParserAgent(client: MockLLMClient(responses: [.text(#"{"records":[]}"#)]))

        do {
            _ = try await agent.parse("深蹲100kg")
            XCTFail("应当抛出空结果错误")
        } catch let error as AgentError {
            XCTAssertEqual(error, .emptyResult)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testPropagatesClientError() async {
        let agent = ParserAgent(client: MockLLMClient(error: LLMError.network("断网")))

        do {
            _ = try await agent.parse("深蹲100kg")
            XCTFail("应当抛出网络错误")
        } catch let error as LLMError {
            XCTAssertEqual(error, .network("断网"))
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testEmptyInputShortCircuits() async {
        let client = MockLLMClient(responses: [.text("{}")])
        let agent = ParserAgent(client: client)

        do {
            _ = try await agent.parse("   ")
            XCTFail("空输入应当直接失败")
        } catch {
            XCTAssertTrue(client.requests.isEmpty, "空输入不应调用 LLM")
        }
    }

    // MARK: - 请求构造

    func testRequestUsesJSONModeAndSystemPrompt() async throws {
        let client = MockLLMClient(responses: [.text(#"{"records":[{"type":"note","note":"x"}]}"#)])
        let agent = ParserAgent(client: client)

        _ = try await agent.parse("测试")

        let request = try XCTUnwrap(client.lastRequest)
        XCTAssertTrue(request.jsonMode)
        XCTAssertEqual(request.messages.first?.role, .system)
        XCTAssertTrue(request.messages.first?.content.contains("深蹲") ?? false, "system prompt 应包含领域示例")
        XCTAssertEqual(request.messages.last?.role, .user)
        XCTAssertEqual(request.messages.last?.content, "测试")
    }

    /// 多轮：历史消息要排在本次输入之前，模型才能理解「再加一组」这类补充
    func testHistoryIsSentBeforeCurrentInput() async throws {
        let client = MockLLMClient(responses: [.text(#"{"records":[{"type":"note","note":"x"}]}"#)])
        let agent = ParserAgent(client: client)

        _ = try await agent.parse(
            "再加一组",
            history: [
                CoachTurn(role: .user, content: "深蹲100kg 5×5"),
                CoachTurn(role: .assistant, content: "上一轮已解析：训练 深蹲 100kg ×5次 5组")
            ]
        )

        let request = try XCTUnwrap(client.lastRequest)
        XCTAssertEqual(request.messages.count, 4)
        XCTAssertEqual(request.messages[0].role, .system)
        XCTAssertEqual(request.messages[1].content, "深蹲100kg 5×5")
        XCTAssertEqual(request.messages[2].role, .assistant)
        XCTAssertEqual(request.messages[3].content, "再加一组")
    }

    func testEmptyHistoryBehavesLikeSingleTurn() async throws {
        let client = MockLLMClient(responses: [.text(#"{"records":[{"type":"note","note":"x"}]}"#)])
        let agent = ParserAgent(client: client)

        _ = try await agent.parse("深蹲100kg")

        let request = try XCTUnwrap(client.lastRequest)
        XCTAssertEqual(request.messages.count, 2)
    }
}
