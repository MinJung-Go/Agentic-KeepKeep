import XCTest
import SwiftData
@testable import AgenticKeepKeep

@MainActor
final class AggregatorTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try AppModelContainer.inMemory()
        return ModelContext(container)
    }

    private func daysAgo(_ days: Int, hour: Int = 12) -> Date {
        let calendar = Calendar.current
        let base = calendar.date(byAdding: .day, value: -days, to: .now) ?? .now
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
    }

    // MARK: - 训练

    func testAggregatesWorkoutCountAndVolume() throws {
        let context = try makeContext()

        for index in 0..<3 {
            let session = WorkoutSession(date: daysAgo(index), title: "训练\(index)")
            context.insert(session)
            let set = ExerciseSet(exerciseName: "深蹲", weightKg: 100, reps: 5, setCount: 5, order: 0)
            set.session = session
            context.insert(set)
        }
        try context.save()

        let digest = try DataAggregator.digest(days: 7, context: context)

        XCTAssertEqual(digest.workoutCount, 3)
        // 每次 100×5×5 = 2500，共 3 次
        XCTAssertEqual(digest.totalVolumeKg, 7_500, accuracy: 1)
        XCTAssertEqual(digest.trends.count, 1)
        XCTAssertEqual(digest.trends[0].name, "深蹲")
        XCTAssertEqual(digest.trends[0].sessions, 3)
    }

    func testExcludesRecordsOutsidePeriod() throws {
        let context = try makeContext()

        let old = WorkoutSession(date: daysAgo(30), title: "很久以前")
        context.insert(old)
        let set = ExerciseSet(exerciseName: "硬拉", weightKg: 120, reps: 3, setCount: 5)
        set.session = old
        context.insert(set)
        try context.save()

        let digest = try DataAggregator.digest(days: 7, context: context)

        XCTAssertEqual(digest.workoutCount, 0)
        XCTAssertEqual(digest.totalVolumeKg, 0)
        XCTAssertTrue(digest.trends.isEmpty)
    }

    func testDetectsStalledExercise() throws {
        let context = try makeContext()

        // 30 天前的好成绩
        let old = WorkoutSession(date: daysAgo(30), title: "腿日")
        context.insert(old)
        let heavy = ExerciseSet(exerciseName: "深蹲", weightKg: 100, reps: 5, setCount: 5)
        heavy.session = old
        context.insert(heavy)

        // 最近掉下来了
        let recent = WorkoutSession(date: daysAgo(2), title: "腿日")
        context.insert(recent)
        let light = ExerciseSet(exerciseName: "深蹲", weightKg: 90, reps: 5, setCount: 5)
        light.session = recent
        context.insert(light)
        try context.save()

        let digest = try DataAggregator.digest(days: 60, context: context)

        let trend = try XCTUnwrap(digest.trends.first)
        XCTAssertEqual(trend.name, "深蹲")
        XCTAssertEqual(trend.bestE1RM, 100 * (1 + 5.0 / 30), accuracy: 0.01)
        XCTAssertEqual(trend.recentE1RM, 90 * (1 + 5.0 / 30), accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(trend.stalledWeeks, 3, "30 天没进步应判定为停滞")
    }

    func testRecentPerformanceClearsStall() throws {
        let context = try makeContext()

        let old = WorkoutSession(date: daysAgo(30), title: "腿日")
        context.insert(old)
        let heavy = ExerciseSet(exerciseName: "深蹲", weightKg: 100, reps: 5, setCount: 5)
        heavy.session = old
        context.insert(heavy)

        // 最近刷新了最佳
        let recent = WorkoutSession(date: daysAgo(1), title: "腿日")
        context.insert(recent)
        let pr = ExerciseSet(exerciseName: "深蹲", weightKg: 105, reps: 5, setCount: 5)
        pr.session = recent
        context.insert(pr)
        try context.save()

        let digest = try DataAggregator.digest(days: 60, context: context)

        XCTAssertEqual(digest.trends.first?.stalledWeeks, 0)
    }

    func testIgnoresBodyweightExercisesWithoutLoad() throws {
        let context = try makeContext()

        let session = WorkoutSession(date: daysAgo(1), title: "核心")
        context.insert(session)
        // 自重动作（无重量）不应进入趋势，也不贡献容量
        let plank = ExerciseSet(exerciseName: "平板支撑", weightKg: 0, reps: 0, setCount: 3)
        plank.session = session
        context.insert(plank)
        try context.save()

        let digest = try DataAggregator.digest(days: 7, context: context)

        XCTAssertEqual(digest.workoutCount, 1)
        XCTAssertEqual(digest.totalVolumeKg, 0)
        XCTAssertTrue(digest.trends.isEmpty)
    }

    // MARK: - 饮食

    func testNutritionAveragesOverLoggedDays() throws {
        let context = try makeContext()

        // 第 1 天：两餐共 2000 kcal
        let dayOne = daysAgo(1)
        for calories in [1_200.0, 800.0] {
            let meal = MealEntry(date: dayOne, mealType: .lunch)
            context.insert(meal)
            let food = FoodItem(name: "测试餐", calories: calories, proteinG: 20, carbsG: 50, fatG: 15)
            food.meal = meal
            context.insert(food)
        }

        // 第 3 天：1000 kcal
        let meal = MealEntry(date: daysAgo(3), mealType: .dinner)
        context.insert(meal)
        let food = FoodItem(name: "测试餐", calories: 1_000, proteinG: 40, carbsG: 100, fatG: 30)
        food.meal = meal
        context.insert(food)

        try context.save()

        let digest = try DataAggregator.digest(days: 7, context: context)

        XCTAssertEqual(digest.nutrition.daysLogged, 2)
        XCTAssertEqual(digest.nutrition.avgCalories, 1_500, accuracy: 1)
        XCTAssertEqual(digest.nutrition.avgProteinG, 40, accuracy: 0.5)
    }

    func testEmptyNutritionWhenNoMeals() throws {
        let context = try makeContext()
        let digest = try DataAggregator.digest(days: 7, context: context)

        XCTAssertEqual(digest.nutrition.daysLogged, 0)
        XCTAssertEqual(digest.nutrition.avgCalories, 0)
    }

    // MARK: - 健康快照

    func testSnapshotAverages() throws {
        let context = try makeContext()

        for (index, sleep) in [6.0, 7.0, 8.0].enumerated() {
            let snapshot = HealthSnapshot(
                day: daysAgo(index + 1),
                sleepHours: sleep,
                hrvMs: 40 + Double(index),
                restingHeartRate: 58,
                steps: 3_000 + index * 1_000
            )
            context.insert(snapshot)
        }
        try context.save()

        let digest = try DataAggregator.digest(days: 7, context: context)

        XCTAssertEqual(digest.sleepAvgHours, 7.0, accuracy: 0.01)
        XCTAssertEqual(digest.sleepMinHours, 6.0, accuracy: 0.01)
        XCTAssertEqual(digest.hrvAvg, 41, accuracy: 0.01)
        XCTAssertEqual(digest.restingHeartRateAvg, 58, accuracy: 0.01)
        XCTAssertEqual(digest.stepsAvgPerDay, 4_000)
    }

    // MARK: - 教练上下文摘要

    func testRecentSummaryText() throws {
        let context = try makeContext()

        let session = WorkoutSession(date: daysAgo(2), title: "腿日")
        context.insert(session)
        let set = ExerciseSet(exerciseName: "深蹲", weightKg: 100, reps: 5, setCount: 5)
        set.session = session
        context.insert(set)

        let snapshot = HealthSnapshot(day: daysAgo(1), sleepHours: 6.4)
        context.insert(snapshot)
        try context.save()

        let summary = try DataAggregator.recentSummary(days: 14, context: context)

        XCTAssertTrue(summary.contains("近 14 天训练 1 次"))
        XCTAssertTrue(summary.contains("日均睡眠 6.4h"))
    }
}
