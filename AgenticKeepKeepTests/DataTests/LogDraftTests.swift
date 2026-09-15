import XCTest
@testable import AgenticKeepKeep

/// 确认卡片的草稿 ↔ 解析结构 往返一致性
@MainActor
final class LogDraftTests: XCTestCase {

    func testWorkoutRoundTrip() throws {
        let parsed = ParsedWorkout(
            title: "腿日",
            exercises: [ParsedExercise(name: "深蹲", weightKg: 100, reps: 5, sets: 5)],
            rpe: 8,
            note: "有点累"
        )

        let draft = try XCTUnwrap(LogDraft.from(ParsedRecord(kind: .workout, workout: parsed)))
        XCTAssertEqual(draft.kind, .workout)
        XCTAssertEqual(draft.workout.title, "腿日")
        XCTAssertEqual(draft.workout.exercises.first?.weightText, "100")
        XCTAssertEqual(draft.workout.exercises.first?.repsText, "5")
        XCTAssertEqual(draft.workout.exercises.first?.setsText, "5")
        XCTAssertEqual(draft.workout.rpeText, "8")

        let back = draft.toParsedRecord()
        XCTAssertEqual(back.kind, .workout)
        XCTAssertEqual(back.workout?.title, "腿日")
        XCTAssertEqual(back.workout?.exercises.first?.weightKg, 100)
        XCTAssertEqual(back.workout?.exercises.first?.reps, 5)
        XCTAssertEqual(back.workout?.exercises.first?.sets, 5)
        XCTAssertEqual(back.workout?.rpe, 8)
    }

    func testWorkoutDraftEditsAreApplied() throws {
        var draft = LogDraft(kind: .workout)
        draft.workout.title = "胸"
        draft.workout.exercises[0].name = "卧推"
        draft.workout.exercises[0].weightText = "82.5"
        draft.workout.exercises[0].repsText = "8"
        draft.workout.exercises[0].setsText = "4"
        draft.workout.exercises.append(ExerciseDraft())

        // 第二个动作没填名字 → 保存时应被过滤掉
        let parsed = draft.toParsedRecord()
        XCTAssertEqual(parsed.workout?.exercises.count, 1)
        XCTAssertEqual(parsed.workout?.exercises.first?.weightKg, 82.5)
        XCTAssertEqual(parsed.workout?.exercises.first?.sets, 4)
    }

    func testMealRoundTrip() throws {
        let parsed = ParsedMeal(
            mealType: "dinner",
            items: [ParsedFood(name: "鸡胸肉", amountText: "200g", calories: 330, proteinG: 62, carbsG: 0, fatG: 7)],
            note: ""
        )

        let draft = try XCTUnwrap(LogDraft.from(ParsedRecord(kind: .meal, meal: parsed)))
        XCTAssertEqual(draft.meal.mealType, .dinner)
        XCTAssertEqual(draft.meal.totalCalories, 330, accuracy: 0.001)
        XCTAssertEqual(draft.meal.totalProtein, 62, accuracy: 0.001)

        let back = draft.toParsedRecord()
        XCTAssertEqual(back.meal?.mealType, "dinner")
        XCTAssertEqual(back.meal?.items.first?.name, "鸡胸肉")
        XCTAssertEqual(back.meal?.items.first?.calories, 330)
        XCTAssertEqual(back.meal?.items.first?.proteinG, 62)
    }

    func testMealTypeFallbackWhenUnrecognized() throws {
        let parsed = ParsedMeal(mealType: "brunch", items: [ParsedFood(name: "三明治", calories: 400)])
        let draft = try XCTUnwrap(LogDraft.from(ParsedRecord(kind: .meal, meal: parsed)))

        // 无法识别时退化为按时间推断，但不会崩
        XCTAssertTrue(MealType.allCases.contains(draft.meal.mealType))
    }

    func testMetricRoundTrip() throws {
        let parsed = ParsedMetric(kind: "weight", value: 74.5)
        let draft = try XCTUnwrap(LogDraft.from(ParsedRecord(kind: .metric, metric: parsed)))

        XCTAssertEqual(draft.metric.kind, .weight)
        XCTAssertEqual(draft.metric.valueText, "74.5")

        let back = draft.toParsedRecord()
        XCTAssertEqual(back.metric?.value, 74.5)
        XCTAssertEqual(back.metric?.kind, "weight")
    }

    func testMetricKindFallsBackToWeight() throws {
        let parsed = ParsedMetric(kind: "unknown_kind", value: 30)
        let draft = try XCTUnwrap(LogDraft.from(ParsedRecord(kind: .metric, metric: parsed)))
        XCTAssertEqual(draft.metric.kind, .weight)
    }

    func testNoteDraft() throws {
        let draft = try XCTUnwrap(LogDraft.from(ParsedRecord(kind: .note, note: "昨晚没睡好")))
        XCTAssertEqual(draft.note.text, "昨晚没睡好")
        XCTAssertEqual(draft.toParsedRecord().note, "昨晚没睡好")
    }

    func testEmptyRecordsProduceNilDraft() {
        XCTAssertNil(LogDraft.from(ParsedRecord(kind: .workout, workout: nil)))
        XCTAssertNil(LogDraft.from(ParsedRecord(kind: .meal, meal: nil)))
        XCTAssertNil(LogDraft.from(ParsedRecord(kind: .metric, metric: nil)))
        XCTAssertNil(LogDraft.from(ParsedRecord(kind: .note, note: "")))
    }

    func testEmptyDetection() {
        var draft = LogDraft(kind: .workout)
        XCTAssertTrue(draft.isEmpty, "新建的空草稿应判定为空")

        draft.workout.exercises[0].name = "深蹲"
        XCTAssertFalse(draft.isEmpty)

        let noteDraft = LogDraft(kind: .note)
        XCTAssertTrue(noteDraft.isEmpty)
    }

    func testManualDraftsHaveSensibleDefaults() {
        let meal = LogDraft(kind: .meal)
        XCTAssertFalse(meal.meal.items.isEmpty, "手动记录时默认给一行空食物")

        let workout = LogDraft(kind: .workout)
        XCTAssertFalse(workout.workout.exercises.isEmpty)
    }

    func testParsedInputHelpers() {
        XCTAssertEqual(ParsedInput.double(" 100 "), 100)
        XCTAssertEqual(ParsedInput.double("82.5"), 82.5)
        XCTAssertNil(ParsedInput.double(""))
        XCTAssertNil(ParsedInput.double("abc"))
        XCTAssertEqual(ParsedInput.int("5"), 5)
        XCTAssertEqual(ParsedInput.int("5.6"), 6)
        XCTAssertEqual(ParsedInput.text(100), "100")
        XCTAssertEqual(ParsedInput.text(82.5), "82.5")
    }
}
