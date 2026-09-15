import SwiftData
import SwiftUI
import XCTest
@testable import AgenticKeepKeep

@MainActor
final class CoachRecordQueryTests: XCTestCase {
    private func date(_ text: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return try XCTUnwrap(formatter.date(from: text))
    }

    func testTodayQueryDoesNotIncludeYesterdayOrPrivateIdentifiers() throws {
        let context = ModelContext(try AppModelContainer.inMemory())
        let now = try date("2026-09-14 18:00")
        context.insert(HealthSnapshot(day: now, steps: 1234))
        context.insert(HealthSnapshot(day: try date("2026-09-13 12:00"), steps: 9999))
        context.insert(HealthWorkout(healthKitUUID: "secret-device-id", date: now.addingTimeInterval(-60), activityName: "步行", durationMinutes: 20))
        try context.save()
        let query = CoachRecordQuery(kind: .health, start_date: "2026-09-14", end_date: "2026-09-14")
        let result = try CoachRecordStore.query(query, context: context, now: now).content
        XCTAssertTrue(result.contains("1234"))
        XCTAssertTrue(result.contains("20.0"))
        XCTAssertFalse(result.contains("9999"))
        XCTAssertFalse(result.contains("secret-device-id"))
        XCTAssertTrue(result.contains("同步时间"))
    }

    func testMissingTodayIsNotFilledWithHistoricalAverage() throws {
        let context = ModelContext(try AppModelContainer.inMemory())
        let now = try date("2026-09-14 18:00")
        context.insert(HealthSnapshot(day: try date("2026-09-13 12:00"), steps: 9999))
        try context.save()
        let result = try CoachRecordStore.query(CoachRecordQuery(kind: .health, start_date: "2026-09-14", end_date: "2026-09-14"), context: context, now: now).content
        XCTAssertTrue(result.contains("步数：没有可用值"))
        XCTAssertFalse(result.contains("9999"))
    }

    func testOldBodyDataCanBeQueriedWithoutSendingNotes() throws {
        let context = ModelContext(try AppModelContainer.inMemory())
        context.insert(BodyMetric(date: try date("2025-01-10 12:00"), value: 70, note: "PRIVATE_RAW_NOTE"))
        try context.save()
        let result = try CoachRecordStore.query(CoachRecordQuery(kind: .body, start_date: "2025-01-01", end_date: "2025-01-31"), context: context, now: try date("2026-09-14 18:00")).content
        XCTAssertTrue(result.contains("70.0"))
        XCTAssertFalse(result.contains("PRIVATE_RAW_NOTE"))
    }

    func testRejectsInvalidFutureAndOversizedDateRanges() throws {
        let now = try date("2026-09-14 18:00")
        for (start, end) in [("2026-02-30", "2026-03-01"), ("2026-01-01", "2026-02-01"),
                             ("2026-09-15", "2026-09-15"), ("2026-09-14", "2026-09-13"),
                             ("2026-9-1", "2026-09-14")] {
            XCTAssertThrowsError(try CoachRecordQuery(kind: .health, start_date: start, end_date: end).interval(now: now))
        }
    }

    func testDayBoundariesFollowDSTInsteadOfFixedSeconds() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let query = CoachRecordQuery(kind: .health, start_date: "2026-03-08", end_date: "2026-03-08")
        let interval = try query.interval(now: date("2026-09-14 18:00"), timeZone: zone)
        XCTAssertEqual(interval.duration, 23 * 3600)
    }

    func testAppearanceMappingAndDefault() {
        XCTAssertNil(AppAppearance.system.colorScheme)
        XCTAssertEqual(AppAppearance.light.colorScheme, .light)
        XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)
    }
    func testPlanQueryReturnsStableIDsAndAllowsFutureSchedule() throws {
        let context = ModelContext(try AppModelContainer.inMemory())
        let plan = Plan(title: "力量训练")
        let day = PlanDay(date: try date("2027-01-02 00:00"), title: "腿部", order: 0)
        context.insert(plan)
        day.plan = plan
        context.insert(day)
        try context.save()
        var query = CoachRecordQuery(kind: .plan, start_date: "2027-01-01", end_date: "2027-01-31")
        query.plan_id = plan.uuid.uuidString
        let result = try CoachRecordStore.query(query, context: context, now: date("2026-09-14 18:00")).content
        XCTAssertTrue(result.contains(plan.uuid.uuidString))
        XCTAssertTrue(result.contains(day.uuid.uuidString))
        XCTAssertTrue(result.contains(PlanMutationStore.revision(plan)))
        XCTAssertTrue(result.contains("2027-01-02"))
    }

}
