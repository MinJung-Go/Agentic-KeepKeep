import XCTest
import SwiftData
@testable import AgenticKeepKeep

@MainActor
final class ModelTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try AppModelContainer.inMemory()
        return ModelContext(container)
    }

    // MARK: - 训练

    func testWorkoutSessionWithSets() throws {
        let context = try makeContext()

        let session = WorkoutSession(date: .now, title: "胸 + 三头")
        context.insert(session)

        let bench = ExerciseSet(exerciseName: "杠铃卧推", weightKg: 80, reps: 8, setCount: 5, rpe: 8, order: 0)
        let fly = ExerciseSet(exerciseName: "哑铃飞鸟", weightKg: 12, reps: 12, setCount: 3, order: 1)
        bench.session = session
        fly.session = session
        context.insert(bench)
        context.insert(fly)

        try context.save()

        let fetched = try context.fetch(FetchDescriptor<WorkoutSession>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].sets.count, 2)
        XCTAssertEqual(fetched[0].exerciseNames, ["杠铃卧推", "哑铃飞鸟"])

        // 容量：80×8×5 + 12×12×3 = 3200 + 432 = 3632
        XCTAssertEqual(fetched[0].totalVolumeKg, 3632, accuracy: 0.001)
    }

    func testExerciseSetDerivedValues() {
        let set = ExerciseSet(exerciseName: "深蹲", weightKg: 100, reps: 5, setCount: 5)
        XCTAssertEqual(set.volumeKg, 2500, accuracy: 0.001)
        // Epley：100 × (1 + 5/30) ≈ 116.67
        XCTAssertEqual(set.estimatedOneRepMax, 116.67, accuracy: 0.01)
        XCTAssertEqual(set.displayText, "100kg × 5次 × 5组")
        XCTAssertEqual(set.formattedWeight, "100kg")
    }

    func testCascadeDeleteRemovesSets() throws {
        let context = try makeContext()

        let session = WorkoutSession(title: "腿日")
        context.insert(session)
        let set = ExerciseSet(exerciseName: "深蹲", weightKg: 100, reps: 5, setCount: 5)
        set.session = session
        context.insert(set)
        try context.save()

        context.delete(session)
        try context.save()

        let sets = try context.fetch(FetchDescriptor<ExerciseSet>())
        XCTAssertTrue(sets.isEmpty, "删除训练时应级联删除其组记录")
    }

    // MARK: - 饮食

    func testMealEntryTotals() throws {
        let context = try makeContext()

        let meal = MealEntry(date: .now, mealType: .lunch, note: "中午吃了牛肉面")
        context.insert(meal)

        let noodles = FoodItem(name: "牛肉面", amountText: "1 碗", calories: 650, proteinG: 30, carbsG: 85, fatG: 18)
        noodles.meal = meal
        context.insert(noodles)

        try context.save()

        let fetched = try context.fetch(FetchDescriptor<MealEntry>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].totalCalories, 650, accuracy: 0.001)
        XCTAssertEqual(fetched[0].totalProteinG, 30, accuracy: 0.001)
        XCTAssertTrue(fetched[0].containsEstimate)
        XCTAssertEqual(fetched[0].summary, "牛肉面")
    }

    func testMealTypeInference() {
        let calendar = Calendar.current
        let breakfast = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: .now)!
        let lunch = calendar.date(bySettingHour: 12, minute: 30, second: 0, of: .now)!
        let dinner = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: .now)!
        let snack = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: .now)!

        XCTAssertEqual(MealType.inferred(from: breakfast), .breakfast)
        XCTAssertEqual(MealType.inferred(from: lunch), .lunch)
        XCTAssertEqual(MealType.inferred(from: dinner), .dinner)
        XCTAssertEqual(MealType.inferred(from: snack), .snack)
    }

    // MARK: - 健康数据

    func testHealthSnapshotRecoveryHint() {
        let low = HealthSnapshot(day: .now, sleepHours: 5.5, hrvMs: 42)
        XCTAssertEqual(low.recoveryHint, "睡眠偏低")

        let lowHRV = HealthSnapshot(day: .now, sleepHours: 8, hrvMs: 30)
        XCTAssertEqual(lowHRV.recoveryHint, "HRV 偏低")

        let ok = HealthSnapshot(day: .now, sleepHours: 7.5, hrvMs: 55)
        XCTAssertNil(ok.recoveryHint)
    }

    func testHealthWorkoutPace() {
        let workout = HealthWorkout(
            healthKitUUID: "HK-001",
            date: .now,
            activityName: "户外跑步",
            durationMinutes: 30,
            distanceKm: 5.2,
            averageHeartRate: 152,
            sourceName: "Apple Watch"
        )
        XCTAssertEqual(workout.paceText, "5'46\"")
        XCTAssertEqual(workout.durationText, "30 分钟")
    }

    func testHealthWorkoutDurationTextHours() {
        let workout = HealthWorkout(healthKitUUID: "HK-002", date: .now, activityName: "骑行", durationMinutes: 95)
        XCTAssertEqual(workout.durationText, "1 小时 35 分")
        XCTAssertNil(workout.paceText)
    }

    // MARK: - 原始笔记与分析报告

    func testRawNoteDefaultsToPending() throws {
        let context = try makeContext()
        let note = RawNote(text: "昨晚只睡了5小时，今天练不动", failureReason: "解析超时")
        context.insert(note)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<RawNote>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].status, .pending)
        XCTAssertEqual(fetched[0].text, "昨晚只睡了5小时，今天练不动")
    }

    func testAnalysisReportTagsRoundTrip() throws {
        let context = try makeContext()
        let report = AnalysisReport(
            periodStart: .now.addingTimeInterval(-7 * 86400),
            periodEnd: .now,
            headline: "深蹲进入平台期",
            body: "恢复不足很可能是主因",
            tags: ["平台期", "恢复警告"],
            citedDataText: "12 次训练 · 7 天睡眠"
        )
        context.insert(report)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<AnalysisReport>())
        XCTAssertEqual(fetched[0].tags, ["平台期", "恢复警告"])
    }

    // MARK: - 课程表

    func testPlanDayLookupAndStatus() throws {
        let context = try makeContext()

        let plan = Plan(title: "4 周哑铃增肌", goal: .muscleGain, weeks: 4)
        context.insert(plan)

        let today = Calendar.current.startOfDay(for: .now)
        let todayDay = PlanDay(date: today, title: "胸+三头", order: 0)
        todayDay.plan = plan
        context.insert(todayDay)

        let exercise = PlanExercise(name: "哑铃卧推", setsText: "4×10", order: 0)
        exercise.day = todayDay
        context.insert(exercise)

        try context.save()

        XCTAssertEqual(plan.days.count, 1)
        XCTAssertNotNil(plan.day(on: .now))
        XCTAssertEqual(plan.completedCount, 0)

        todayDay.status = .done
        XCTAssertEqual(plan.completedCount, 1)
        XCTAssertEqual(todayDay.exerciseSummary, "哑铃卧推")
    }

    // MARK: - 教练对话

    func testChatMessagePendingPlan() throws {
        let context = try makeContext()

        let user = ChatMessage(role: .user, content: "我想增肌，每周4天，家里只有哑铃")
        let assistant = ChatMessage(
            role: .assistant,
            content: "已为你生成 4 周计划",
            pendingPlanJSON: "{\"title\":\"4周哑铃增肌\"}",
            pendingPlanTitle: "4 周哑铃增肌"
        )
        context.insert(user)
        context.insert(assistant)
        try context.save()

        XCTAssertFalse(user.hasPendingPlan)
        XCTAssertTrue(assistant.hasPendingPlan)
        XCTAssertEqual(assistant.pendingPlanTitle, "4 周哑铃增肌")
    }

    // MARK: - 模型容器

    func testContainerSchemaCoversAllModels() throws {
        // 全部模型都能在容器中正常存取（schema 登记完整性）
        let context = try makeContext()
        context.insert(BodyMetric(kind: .weight, value: 74.5))
        context.insert(HealthSnapshot(day: .now, sleepHours: 6.5))
        context.insert(RawNote(text: "测试"))
        try context.save()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BodyMetric>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthSnapshot>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RawNote>()), 1)
    }
}
