import XCTest
import SwiftData
@testable import AgenticKeepKeep

@MainActor
final class PlanExerciseStoreTests: XCTestCase {
    private func fixture() throws -> (ModelContext, PlanDay, PlanExercise) {
        let context = ModelContext(try AppModelContainer.inMemory())
        context.autosaveEnabled = false
        let day = PlanDay(date: .now, title: "力量")
        let exercise = PlanExercise(name: "深蹲", setsText: "3×10", targetWeightKg: 20)
        context.insert(day)
        context.insert(exercise)
        exercise.day = day
        try context.save()
        return (context, day, exercise)
    }

    func testEditingDraftAndDiscardingItDoesNotChangeOrDeleteExercise() throws {
        let (context, day, exercise) = try fixture()
        var draft = PlanExerciseEditDraft(exercise)
        draft.name = "未保存的名称"
        draft.weightText = "99"
        XCTAssertEqual(exercise.name, "深蹲")
        XCTAssertEqual(exercise.targetWeightKg, 20)
        XCTAssertEqual(day.exercises.count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanExercise>()), 1)
        XCTAssertFalse(context.hasChanges)
    }

    func testSavePersistsParametersAndKeepsRelationship() throws {
        let (context, day, exercise) = try fixture()
        var draft = PlanExerciseEditDraft(exercise)
        draft.name = " 杠铃深蹲 "
        draft.setsText = "4×8"
        draft.weightText = "0"
        try PlanExerciseStore.save(draft, id: exercise.uuid, context: context)
        let reader = ModelContext(context.container)
        let saved = try XCTUnwrap(reader.fetch(FetchDescriptor<PlanExercise>()).first)
        XCTAssertEqual(saved.name, "杠铃深蹲")
        XCTAssertEqual(saved.setsText, "4×8")
        XCTAssertEqual(saved.targetWeightKg, 0)
        XCTAssertEqual(saved.day?.uuid, day.uuid)
        draft.weightText = ""
        try PlanExerciseStore.save(draft, id: exercise.uuid, context: context)
        XCTAssertNil(exercise.targetWeightKg)
    }

    func testInvalidSaveDoesNotPartiallyModifyExercise() throws {
        let (context, _, exercise) = try fixture()
        for weight in ["-1", "NaN", "inf", "2001", "abc"] {
            var draft = PlanExerciseEditDraft(exercise)
            draft.name = "不能写入"
            draft.weightText = weight
            XCTAssertThrowsError(try PlanExerciseStore.save(draft, id: exercise.uuid, context: context))
            XCTAssertEqual(exercise.name, "深蹲")
            XCTAssertEqual(exercise.targetWeightKg, 20)
        }
    }

    func testDeleteOnlyRemovesSelectedExerciseAndPreservesWorkoutHistory() throws {
        let (context, day, exercise) = try fixture()
        let other = PlanExercise(name: "卧推")
        context.insert(other)
        other.day = day
        let session = WorkoutSession(title: "已完成的训练")
        context.insert(session)
        let set = ExerciseSet(exerciseName: "深蹲", weightKg: 20, reps: 10)
        context.insert(set)
        set.session = session
        try context.save()
        try PlanExerciseStore.delete(id: exercise.uuid, day: day, context: context)
        XCTAssertEqual(day.exercises.map(\.uuid), [other.uuid])
        let reader = ModelContext(context.container)
        XCTAssertEqual(try reader.fetchCount(FetchDescriptor<PlanExercise>()), 1)
        XCTAssertEqual(try reader.fetchCount(FetchDescriptor<ExerciseSet>()), 1)
        XCTAssertEqual(try reader.fetchCount(FetchDescriptor<WorkoutSession>()), 1)
        XCTAssertThrowsError(try PlanExerciseStore.delete(id: other.uuid, day: PlanDay(date: .now, title: "别的日期"), context: context))
        XCTAssertEqual(day.exercises.count, 1)
    }
}
