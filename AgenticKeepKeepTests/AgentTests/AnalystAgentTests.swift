import XCTest
@testable import AgenticKeepKeep

final class AnalystAgentTests: XCTestCase {

    private func sampleDigest() -> AnalysisDigest {
        var digest = AnalysisDigest(
            periodStart: Date().addingTimeInterval(-7 * 86_400),
            periodEnd: .now
        )
        digest.workoutCount = 4
        digest.totalVolumeKg = 12_500
        digest.trends = [
            ExerciseTrend(name: "深蹲", sessions: 4, bestE1RM: 120, recentE1RM: 118, stalledWeeks: 3)
        ]
        digest.sleepAvgHours = 6.2
        digest.sleepMinHours = 5.1
        digest.hrvAvg = 38
        digest.restingHeartRateAvg = 58
        digest.stepsAvgPerDay = 3_200
        digest.nutrition = NutritionDigest(
            daysLogged: 5,
            avgCalories: 2_100,
            avgProteinG: 82,
            avgCarbsG: 230,
            avgFatG: 65
        )
        return digest
    }

    func testDigestSummaryTextContainsKeyFacts() {
        let text = sampleDigest().summaryText()

        XCTAssertTrue(text.contains("训练：共 4 次"))
        XCTAssertTrue(text.contains("深蹲"))
        XCTAssertTrue(text.contains("停滞 3 周"))
        XCTAssertTrue(text.contains("日均 6.2 小时"))
        XCTAssertTrue(text.contains("HRV"))
        XCTAssertTrue(text.contains("5 天有记录"))
    }

    func testDigestSummaryHandlesEmptyPeriod() {
        var digest = AnalysisDigest(periodStart: .now, periodEnd: .now)
        digest.workoutCount = 0

        let text = digest.summaryText()

        XCTAssertTrue(text.contains("没有训练记录"))
        XCTAssertTrue(text.contains("没有记录"))
    }

    func testGeneratesReportDraft() async throws {
        let json = """
        {"headline":"深蹲进入平台期，恢复不足可能是主因","body":"近一周深蹲重量停滞3周，同期日均睡眠仅6.2小时。建议本周减载15%。","tags":["平台期","恢复警告"],"citedData":"4 次训练 · 7 天睡眠"}
        """
        let client = MockLLMClient(responses: [.text(json)])
        let agent = AnalystAgent(client: client)

        let draft = try await agent.generateReport(from: sampleDigest())

        XCTAssertEqual(draft.headline, "深蹲进入平台期，恢复不足可能是主因")
        XCTAssertEqual(draft.tags, ["平台期", "恢复警告"])
        XCTAssertEqual(draft.citedData, "4 次训练 · 7 天睡眠")
        XCTAssertFalse(draft.body.isEmpty)
    }

    func testReportRequestSendsOnlyDigestNotRawData() async throws {
        let json = #"{"headline":"h","body":"b","tags":[],"citedData":"c"}"#
        let client = MockLLMClient(responses: [.text(json)])
        let agent = AnalystAgent(client: client)

        _ = try await agent.generateReport(from: sampleDigest())

        let request = try XCTUnwrap(client.lastRequest)
        let userContent = try XCTUnwrap(request.messages.last?.content)

        // 隐私约束：发给模型的是聚合摘要
        XCTAssertTrue(userContent.contains("统计区间"))
        XCTAssertTrue(userContent.contains("总容量"))
        // 摘要里不应该出现逐条原始记录才有的字段
        XCTAssertFalse(userContent.contains("proteinG"))
        XCTAssertFalse(userContent.contains("healthKitUUID"))
    }

    func testThrowsOnMalformedReport() async {
        let agent = AnalystAgent(client: MockLLMClient(responses: [.text("我觉得你练得不错")]))

        do {
            _ = try await agent.generateReport(from: sampleDigest())
            XCTFail("非 JSON 应当报错")
        } catch {
            XCTAssertTrue(error is AgentError)
        }
    }

    func testToleratesMissingOptionalFields() async throws {
        let json = #"{"headline":"只有一句话"}"#
        let agent = AnalystAgent(client: MockLLMClient(responses: [.text(json)]))

        let draft = try await agent.generateReport(from: sampleDigest())

        XCTAssertEqual(draft.headline, "只有一句话")
        XCTAssertEqual(draft.body, "")
        XCTAssertTrue(draft.tags.isEmpty)
    }
}
