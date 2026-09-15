import SwiftData
import XCTest
@testable import AgenticKeepKeep

@MainActor
final class HealthInsightsTests: XCTestCase {
    private func context() throws -> ModelContext { ModelContext(try AppModelContainer.inMemory()) }

    func testOnlyHealthWorkoutsCanGenerateReport() async throws {
        let context = try context()
        context.insert(HealthWorkout(healthKitUUID: "private-id", date: .now.addingTimeInterval(-60),
                                     activityName: "跑步", durationMinutes: 30, distanceKm: 5))
        try context.save()
        let digest = try DataAggregator.digest(context: context)
        XCTAssertTrue(digest.hasData)
        XCTAssertEqual(digest.workoutCount, 0)
        XCTAssertEqual(digest.healthActivity?.workoutCount, 1)
        let client = MockLLMClient(responses: [.text(#"{"headline":"活动概况","body":"训练 30 分钟","tags":[],"citedData":"1 次"}"#)])
        _ = try await AnalystAgent(client: client).generateReport(from: digest)
        let message = try XCTUnwrap(client.lastRequest?.messages.last?.content)
        XCTAssertTrue(message.contains("Apple 健康运动：已同步 1 次"))
        XCTAssertTrue(message.contains("30 分钟"))
        XCTAssertFalse(message.contains("private-id"))
    }

    func testStepsEnergyAndRecoveryEachAllowAnalysis() throws {
        for sample in [HealthSnapshot(day: .now, steps: 5000),
                       HealthSnapshot(day: .now, activeEnergyKcal: 300),
                       HealthSnapshot(day: .now, sleepHours: 7),
                       HealthSnapshot(day: .now, hrvMs: 40),
                       HealthSnapshot(day: .now, restingHeartRate: 60)] {
            let context = try context()
            context.insert(sample)
            try context.save()
            XCTAssertTrue(try DataAggregator.digest(context: context).hasData)
        }
    }

    func testEmptyDataDoesNotCallModel() async throws {
        let context = try context()
        context.insert(HealthSnapshot(day: .now))
        try context.save()
        let digest = try DataAggregator.digest(context: context)
        XCTAssertFalse(digest.hasData)
        let client = MockLLMClient()
        do {
            _ = try await AnalystAgent(client: client).generateReport(from: digest)
            XCTFail("Empty data must not generate a report")
        } catch {
            XCTAssertTrue(error is ReportGenerationError)
        }
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testSingleDayHealthDataProducesChartsWithoutZeroFilling() throws {
        let now = Date.now
        let samples = [HealthSnapshot(day: now, steps: 1234, activeEnergyKcal: 200),
                       HealthSnapshot(day: now.addingTimeInterval(-86400)),
                       HealthSnapshot(day: now.addingTimeInterval(-40 * 86400), steps: 9999)]
        let workouts = [HealthWorkout(healthKitUUID: "one", date: now.addingTimeInterval(-60),
                                      activityName: "步行", durationMinutes: 10),
                        HealthWorkout(healthKitUUID: "two", date: now.addingTimeInterval(-120),
                                      activityName: "步行", durationMinutes: 20)]
        let series = HealthTrendSeries.build(snapshots: samples, workouts: workouts, days: 7, now: now)
        let steps = try XCTUnwrap(series.first { $0.metric == .steps })
        XCTAssertEqual(steps.points.count, 1)
        XCTAssertEqual(steps.points.first?.value, 1234)
        XCTAssertEqual(series.first { $0.metric == .minutes }?.points.first?.value, 30)
        XCTAssertEqual(series.first { $0.metric == .count }?.points.first?.value, 2)
        XCTAssertTrue(HealthTrendSeries.build(snapshots: [], workouts: [], days: 7).isEmpty)
    }

    func testTodayStepsRemainDistinctFromPeriodAverage() throws {
        let context = try context()
        let today = Date.now
        context.insert(HealthSnapshot(day: today, steps: 1000))
        context.insert(HealthSnapshot(day: today.addingTimeInterval(-86400), steps: 9000))
        try context.save()
        let text = try CoachContextBuilder.build(context: context, now: today).profileText
        XCTAssertTrue(text.contains("今天步数 1000 步"))
        XCTAssertTrue(text.contains("日均步数 5000"))
        XCTAssertTrue(text.contains("健康快照更新于"))
        XCTAssertTrue(text.contains("并非实时读数"))
    }

    func testYesterdayStepsDoNotBecomeTodaySteps() throws {
        let context = try context()
        context.insert(HealthSnapshot(day: Date.now.addingTimeInterval(-86400), steps: 9000))
        try context.save()
        let text = try CoachContextBuilder.build(context: context).profileText
        XCTAssertTrue(text.contains("今天尚无已同步的健康快照"))
        XCTAssertFalse(text.contains("今天步数 9000"))
    }

    func testSevenDayReportExcludesEighthCalendarDay() throws {
        let context = try context()
        let today = Calendar.current.startOfDay(for: .now)
        let old = Calendar.current.date(byAdding: .day, value: -7, to: today)!
        context.insert(HealthSnapshot(day: old, steps: 9000))
        try context.save()
        XCTAssertFalse(try DataAggregator.digest(days: 7, context: context).hasData)
    }
}
