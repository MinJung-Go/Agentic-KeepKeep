import XCTest
@testable import AgenticKeepKeep

final class CoachAgentTests: XCTestCase {

    func testDecodesPlanDraftFromToolCall() async throws {
        let arguments = """
        {"title":"4 周哑铃增肌计划","goal":"muscleGain","weeks":4,"days":[
          {"dayOffset":0,"title":"胸 + 三头","exercises":[
            {"name":"哑铃卧推","setsText":"4×10","targetWeightKg":20},
            {"name":"哑铃飞鸟","setsText":"3×12"}
          ]},
          {"dayOffset":1,"title":"背 + 二头","exercises":[{"name":"单臂划船","setsText":"4×12"}]}
        ]}
        """
        let call = LLMToolCall(id: "call_1", name: "create_plan", argumentsJSON: arguments)
        let client = MockLLMClient(responses: [.calls([call], content: "已为你生成计划")])
        let agent = CoachAgent(client: client)

        let reply = try await agent.reply(
            history: [],
            userMessage: "我想增肌，每周4天，家里只有哑铃",
            context: CoachContext()
        )

        XCTAssertEqual(reply.text, "已为你生成计划")
        let draft = try XCTUnwrap(reply.planDraft)
        XCTAssertEqual(draft.title, "4 周哑铃增肌计划")
        XCTAssertEqual(draft.goal, "muscleGain")
        XCTAssertEqual(draft.weeks, 4)
        XCTAssertEqual(draft.days.count, 2)
        XCTAssertEqual(draft.days[0].dayOffset, 0)
        XCTAssertEqual(draft.days[0].title, "胸 + 三头")
        XCTAssertEqual(draft.days[0].exercises.first?.name, "哑铃卧推")
        XCTAssertEqual(draft.days[0].exercises.first?.setsText, "4×10")
        XCTAssertEqual(draft.days[0].exercises.first?.targetWeightKg, 20)
    }

    func testDecodesAdjustmentDraft() async throws {
        let arguments = """
        {"summary":"连续3天睡眠不足，建议减载","changes":[
          {"dayOffset":2,"action":"deload","detail":"重量降到 RPE 7"}
        ]}
        """
        let call = LLMToolCall(id: "call_2", name: "propose_plan_adjustment", argumentsJSON: arguments)
        let agent = CoachAgent(client: MockLLMClient(responses: [.calls([call])]))

        let reply = try await agent.reply(history: [], userMessage: "最近很累")

        let draft = try XCTUnwrap(reply.adjustmentDraft)
        XCTAssertEqual(draft.changes.count, 1)
        XCTAssertEqual(draft.changes[0].action, "deload")
        XCTAssertEqual(draft.changes[0].dayOffset, 2)
    }

    func testPlainTextReplyWithoutToolCall() async throws {
        let agent = CoachAgent(client: MockLLMClient(responses: [.text("你每周能练几天？")]))

        let reply = try await agent.reply(history: [], userMessage: "我想练力量")

        XCTAssertEqual(reply.text, "你每周能练几天？")
        XCTAssertNil(reply.planDraft)
        XCTAssertFalse(reply.isEmpty)
    }

    func testThrowsWhenReplyIsEmpty() async {
        let agent = CoachAgent(client: MockLLMClient(responses: [LLMResponse(content: nil, toolCalls: [])]))

        do {
            _ = try await agent.reply(history: [], userMessage: "你好")
            XCTFail("空回复应当报错")
        } catch let error as AgentError {
            XCTAssertEqual(error, .emptyResponse)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testUnknownToolCallIsIgnored() async {
        let call = LLMToolCall(id: "x", name: "some_other_tool", argumentsJSON: "{}")
        let agent = CoachAgent(client: MockLLMClient(responses: [.calls([call], content: "好的")]))

        do {
            let reply = try await agent.reply(history: [], userMessage: "你好")
            XCTAssertNil(reply.planDraft)
            XCTAssertEqual(reply.text, "好的")
        } catch {
            XCTFail("不应抛错：\(error)")
        }
    }

    func testRequestIncludesToolsAndHistory() async throws {
        let client = MockLLMClient(responses: [.text("好的")])
        let agent = CoachAgent(client: client)

        _ = try await agent.reply(
            history: [
                CoachTurn(role: .user, content: "我想增肌"),
                CoachTurn(role: .assistant, content: "每周能练几天？")
            ],
            userMessage: "4天",
            context: CoachContext(goal: "增肌", availableEquipment: "哑铃", daysPerWeek: 4, recentSummary: "近14天训练6次")
        )

        let request = try XCTUnwrap(client.lastRequest)
        XCTAssertEqual(request.tools.count, 2)
        XCTAssertEqual(request.tools.map(\.name).sorted(), ["create_plan", "propose_plan_adjustment"])

        // system + 2 轮历史 + 本次输入
        XCTAssertEqual(request.messages.count, 4)
        XCTAssertEqual(request.messages[0].role, .system)
        XCTAssertTrue(request.messages[0].content.contains("哑铃"))
        XCTAssertTrue(request.messages[0].content.contains("近14天训练6次"))
        XCTAssertEqual(request.messages[1].content, "我想增肌")
        XCTAssertEqual(request.messages[2].role, .assistant)
        XCTAssertEqual(request.messages[3].content, "4天")
    }

    func testCreatePlanToolSchemaShape() throws {
        let tool = CoachAgent.createPlanTool
        XCTAssertEqual(tool.name, "create_plan")

        let parameters = try XCTUnwrap(tool.parameters.objectValue)
        XCTAssertEqual(parameters["type"]?.stringValue, "object")
        let required = try XCTUnwrap(parameters["required"]?.arrayValue?.compactMap(\.stringValue))
        XCTAssertEqual(Set(required), ["title", "goal", "weeks", "days"])

        let properties = try XCTUnwrap(parameters["properties"]?.objectValue)
        XCTAssertNotNil(properties["days"])
    }
}
