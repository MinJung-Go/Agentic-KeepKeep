import SwiftData
import XCTest
@testable import AgenticKeepKeep

/// 教练能看到的「个人概况」：训练 / 恢复 / 饮食 / 身体 / 课程表
@MainActor
final class CoachContextBuilderTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.inMemory())
    }

    private func daysAgo(_ days: Int, hour: Int = 12) -> Date {
        let calendar = Calendar.current
        let base = calendar.date(byAdding: .day, value: -days, to: .now) ?? .now
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
    }

    private func seedWorkout(
        in context: ModelContext,
        daysAgo days: Int,
        exercise: String,
        weightKg: Double,
        reps: Int = 5,
        sets: Int = 5
    ) {
        let session = WorkoutSession(date: daysAgo(days), title: "训练")
        context.insert(session)
        let set = ExerciseSet(exerciseName: exercise, weightKg: weightKg, reps: reps, setCount: sets)
        set.session = session
        context.insert(set)
    }

    func testProfileContainsAllSections() throws {
        let context = try makeContext()

        seedWorkout(in: context, daysAgo: 2, exercise: "深蹲", weightKg: 100)
        seedWorkout(in: context, daysAgo: 30, exercise: "深蹲", weightKg: 110)

        let meal = MealEntry(date: daysAgo(1), mealType: .lunch)
        context.insert(meal)
        let food = FoodItem(name: "鸡胸肉", calories: 330, proteinG: 62, carbsG: 0, fatG: 7)
        food.meal = meal
        context.insert(food)

        context.insert(HealthSnapshot(day: daysAgo(1), sleepHours: 6.4, hrvMs: 38, restingHeartRate: 58))
        context.insert(BodyMetric(date: daysAgo(20), kind: .weight, value: 75))
        context.insert(BodyMetric(date: daysAgo(1), kind: .weight, value: 74.2))

        let plan = Plan(title: "4 周哑铃增肌", goal: .muscleGain, weeks: 4)
        context.insert(plan)
        let day = PlanDay(date: daysAgo(1), title: "胸 + 三头")
        day.plan = plan
        day.statusRaw = PlanDayStatus.done.rawValue
        context.insert(day)

        try context.save()

        let text = try CoachContextBuilder.profileText(context: context, days: 28)

        XCTAssertTrue(text.contains("【训练】"), "要有训练段")
        XCTAssertTrue(text.contains("深蹲"), "要列出主要动作")
        XCTAssertTrue(text.contains("【恢复】"), "要有恢复段")
        XCTAssertTrue(text.contains("日均睡眠 6.4h"), "睡眠要精确到小数")
        XCTAssertTrue(text.contains("【饮食】"), "要有饮食段")
        XCTAssertTrue(text.contains("蛋白质 62g"), "要有蛋白质")
        XCTAssertTrue(text.contains("【身体】"), "要有体重段")
        XCTAssertTrue(text.contains("74.2"), "要有最新体重")
        XCTAssertTrue(text.contains("【课程表】"), "要有课程表段")
        XCTAssertTrue(text.contains("4 周哑铃增肌"))
    }

    func testTrainingLineMentionsStall() throws {
        let context = try makeContext()

        seedWorkout(in: context, daysAgo: 30, exercise: "卧推", weightKg: 90)
        seedWorkout(in: context, daysAgo: 2, exercise: "卧推", weightKg: 80)
        try context.save()

        let text = try CoachContextBuilder.profileText(context: context, days: 60)

        XCTAssertTrue(text.contains("停滞"), "退步的动作要标出停滞周数")
    }

    func testNutritionLineShowsProteinGap() throws {
        let context = try makeContext()

        context.insert(BodyMetric(date: daysAgo(1), kind: .weight, value: 75))
        let meal = MealEntry(date: daysAgo(1), mealType: .lunch)
        context.insert(meal)
        let food = FoodItem(name: "鸡胸肉", calories: 500, proteinG: 60)
        food.meal = meal
        context.insert(food)
        try context.save()

        let text = try CoachContextBuilder.profileText(context: context, days: 7)

        // 目标 75 × 1.6 = 120g，实际 60g → 差 60g
        XCTAssertTrue(text.contains("目标 120g"), "要有蛋白质目标")
        XCTAssertTrue(text.contains("差 60g"), "要有缺口")
    }

    func testMissingDataOmitsSections() throws {
        let context = try makeContext()
        // 什么都不放

        let text = try CoachContextBuilder.profileText(context: context, days: 28)

        XCTAssertTrue(text.contains("【训练】"), "训练段始终存在（说明没有记录）")
        XCTAssertTrue(text.contains("0 次"))
        XCTAssertFalse(text.contains("【饮食】"), "没有饮食记录就不该有饮食段")
        XCTAssertFalse(text.contains("【身体】"), "没有体重就不该有身体段")
        XCTAssertFalse(text.contains("【恢复】"), "没有健康数据就不该有恢复段")
    }

    func testLastWorkoutRecency() throws {
        let context = try makeContext()

        seedWorkout(in: context, daysAgo: 1, exercise: "深蹲", weightKg: 100)
        try context.save()

        let text = try CoachContextBuilder.profileText(context: context, days: 28)

        XCTAssertTrue(text.contains("最近一次是昨天"), "要能说清多久没练")
    }

    func testBuildReturnsBothSummaryAndProfile() throws {
        let context = try makeContext()

        seedWorkout(in: context, daysAgo: 1, exercise: "深蹲", weightKg: 100)
        try context.save()

        let coachContext = try CoachContextBuilder.build(context: context, days: 28)

        XCTAssertFalse(coachContext.profileText.isEmpty)
        XCTAssertFalse(coachContext.recentSummary.isEmpty, "保留一行式摘要供兼容")
    }

    func testHealthWorkoutsAndActivityReachCoachMessages() throws {
        let context = try makeContext()
        context.insert(HealthWorkout(healthKitUUID: "private-watch-id", date: daysAgo(1),
            activityName: "跑步", durationMinutes: 30, distanceKm: 5, sourceName: "private-device"))
        context.insert(HealthWorkout(healthKitUUID: "ride", date: daysAgo(2),
            activityName: "骑行", durationMinutes: 60))
        context.insert(HealthSnapshot(day: daysAgo(1), steps: 8000, activeEnergyKcal: 600))
        context.insert(HealthSnapshot(day: daysAgo(2), steps: 4000, activeEnergyKcal: 400))
        context.insert(HealthSnapshot(day: daysAgo(3))) // 缺失不能拉低平均数
        try context.save()

        let coach = try CoachContextBuilder.build(context: context)
        let messages = CoachAgent.buildMessages(history: [], userMessage: "分析我的运动", context: coach)
        let system = try XCTUnwrap(messages.first).content
        XCTAssertTrue(system.contains("已同步 2 次，累计 90 分钟"))
        XCTAssertTrue(system.contains("已记录距离合计 5km（1 次有距离）"))
        XCTAssertTrue(system.contains("跑步 1 次"))
        XCTAssertTrue(system.contains("骑行 1 次"))
        XCTAssertTrue(system.contains("日均步数 6000（2 天有值）"))
        XCTAssertTrue(system.contains("日均活动能量 500kcal"))
        XCTAssertTrue(system.contains("非单次训练消耗"))
        XCTAssertTrue(system.contains("Moveliq 内记录"))
        XCTAssertFalse(system.contains("private-watch-id"))
        XCTAssertFalse(system.contains("private-device"))
    }

    func testHealthSummaryExcludesOutsideWindowAndRefreshesAfterImport() throws {
        let context = try makeContext()
        let now = Date.now
        context.insert(HealthWorkout(healthKitUUID: "old", date: now.addingTimeInterval(-40 * 86400),
            activityName: "旧运动", durationMinutes: 100))
        context.insert(HealthWorkout(healthKitUUID: "future", date: now.addingTimeInterval(86400),
            activityName: "未来运动", durationMinutes: 100))
        try context.save()
        let before = try CoachContextBuilder.build(context: context, now: now)
        XCTAssertTrue(before.profileText.contains("没有已同步的训练记录"))
        XCTAssertFalse(before.profileText.contains("旧运动"))
        XCTAssertFalse(before.profileText.contains("未来运动"))

        context.insert(HealthWorkout(healthKitUUID: "new", date: now.addingTimeInterval(-3600),
            activityName: "游泳", durationMinutes: 20))
        try context.save()
        let after = try CoachContextBuilder.build(context: context, now: now)
        XCTAssertTrue(after.profileText.contains("已同步 1 次，累计 20 分钟"))
        XCTAssertTrue(after.profileText.contains("游泳 1 次"))
        XCTAssertFalse(after.profileText.contains("没有已同步的训练记录"))
    }

    func testMissingHealthValuesAreNotReportedAsZeroActivity() throws {
        let context = try makeContext()
        context.insert(HealthSnapshot(day: daysAgo(1), sleepHours: 7))
        try context.save()
        let text = try CoachContextBuilder.profileText(context: context)
        XCTAssertTrue(text.contains("不代表没有运动或未授权"))
        XCTAssertFalse(text.contains("日均步数"))
        XCTAssertFalse(text.contains("日均活动能量"))
        XCTAssertTrue(text.contains("日均睡眠 7h"))
    }

}
