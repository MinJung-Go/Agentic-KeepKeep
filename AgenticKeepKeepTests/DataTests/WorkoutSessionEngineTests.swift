import XCTest
@testable import AgenticKeepKeep

/// 训练会话的推进逻辑。这一轮最容易出错的地方全在这儿，所以测得细一些。
final class WorkoutSessionEngineTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func exercise(
        _ name: String,
        sets: Int? = 3,
        reps: Int? = 10,
        weight: Double? = 60,
        text: String = "3×10"
    ) -> WorkoutSessionEngine.Exercise {
        WorkoutSessionEngine.Exercise(
            id: UUID(), name: name,
            plannedSets: sets, plannedReps: reps, plannedWeightKg: weight, setsText: text
        )
    }

    // MARK: - 组次文案解析

    func testParseCommonSetNotations() {
        for text in ["4×10", "4x10", "4*10", "4 组 × 10 次", "4×10次", "4 × 10"] {
            let parsed = SetSpecParser.parse(text)
            XCTAssertEqual(parsed?.sets, 4, "「\(text)」应当解析成 4 组")
            XCTAssertEqual(parsed?.reps, 10, "「\(text)」应当解析成 10 次")
        }
    }

    /// 解析不出来就返回 nil —— 界面显示原文，**不编造组次**
    func testParseRejectsUnparsableText() {
        for text in ["", "力竭", "4", "×10", "4×", "四组十次", "4×10×2"] {
            XCTAssertNil(SetSpecParser.parse(text), "「\(text)」不该被解析出组次")
        }
    }

    func testParseRejectsZero() {
        XCTAssertNil(SetSpecParser.parse("0×10"))
        XCTAssertNil(SetSpecParser.parse("4×0"))
    }

    // MARK: - 推进

    func testCompleteSetAdvancesSetIndex() {
        var engine = WorkoutSessionEngine(exercises: [exercise("卧推")], startedAt: t0)
        XCTAssertEqual(engine.nextSetIndex(for: engine.exercises[0]), 1)

        engine.completeSet(weightKg: 60, reps: 10, at: t0)
        XCTAssertEqual(engine.nextSetIndex(for: engine.exercises[0]), 2)

        engine.completeSet(weightKg: 60, reps: 10, at: t0)
        XCTAssertEqual(engine.nextSetIndex(for: engine.exercises[0]), 3)
    }

    func testCompleteSetReportsWhenExerciseIsDone() {
        var engine = WorkoutSessionEngine(exercises: [exercise("卧推", sets: 2)], startedAt: t0)
        XCTAssertFalse(engine.completeSet(weightKg: 60, reps: 10, at: t0), "还差一组")
        XCTAssertTrue(engine.completeSet(weightKg: 60, reps: 10, at: t0), "做满了 2 组")
    }

    /// **解析不出组数的计划永远不算完成** —— 那说明计划里写的是别的格式，
    /// 不该替用户决定「你做够了」
    func testUnparsablePlanNeverAutoFinishes() {
        var engine = WorkoutSessionEngine(
            exercises: [exercise("卧推", sets: nil, reps: nil, text: "力竭")],
            startedAt: t0
        )
        for _ in 0..<10 {
            XCTAssertFalse(engine.completeSet(weightKg: 60, reps: 10, at: t0))
        }
        XCTAssertFalse(engine.currentExercise.map(engine.isExerciseFinished) ?? true)
    }

    func testAdvanceToNextUnfinished() {
        let a = exercise("卧推", sets: 1)
        let b = exercise("划船", sets: 1)
        var engine = WorkoutSessionEngine(exercises: [a, b], startedAt: t0)

        engine.completeSet(weightKg: 60, reps: 10, at: t0)
        XCTAssertTrue(engine.isExerciseFinished(engine.exercises[0]))

        engine.advanceToNextUnfinished()
        XCTAssertEqual(engine.currentIndex, 1)
    }

    /// 后面没有未完成的就回头找，**不绕回开头** —— 循环会让人以为漏了什么
    func testAdvanceDoesNotWrapAround() {
        let a = exercise("卧推", sets: 1)
        let b = exercise("划船", sets: 1)
        var engine = WorkoutSessionEngine(exercises: [a, b], startedAt: t0)

        engine.moveTo(index: 1)
        engine.completeSet(weightKg: 60, reps: 10, at: t0)   // 做完了 b
        engine.advanceToNextUnfinished()                      // a 还没做，应回头找 a
        XCTAssertEqual(engine.currentIndex, 0)

        engine.completeSet(weightKg: 60, reps: 10, at: t0)   // a 也做完了
        engine.advanceToNextUnfinished()
        XCTAssertEqual(engine.currentIndex, 0, "全做完了就停在原地，不该绕圈")
    }

    func testMoveToIgnoresOutOfRange() {
        var engine = WorkoutSessionEngine(exercises: [exercise("卧推")], startedAt: t0)
        engine.moveTo(index: 99)
        XCTAssertEqual(engine.currentIndex, 0)
    }

    // MARK: - 多做 / 少做 / 撤回

    func testMultipleSetsAtDifferentWeights() {
        // 第 4 组减重 —— 这正是「每组一条」要记下来的情况
        var engine = WorkoutSessionEngine(exercises: [exercise("卧推", sets: 4)], startedAt: t0)
        for _ in 0..<3 { engine.completeSet(weightKg: 80, reps: 8, at: t0) }
        engine.completeSet(weightKg: 70, reps: 8, at: t0)

        let weights = engine.sets(for: engine.exercises[0]).map(\.weightKg)
        XCTAssertEqual(weights, [80, 80, 80, 70])
    }

    func testUndoRemovesLastSet() {
        var engine = WorkoutSessionEngine(exercises: [exercise("卧推")], startedAt: t0)
        engine.completeSet(weightKg: 60, reps: 10, at: t0)
        engine.completeSet(weightKg: 60, reps: 10, at: t0)

        engine.undoSet(for: engine.exercises[0])
        XCTAssertEqual(engine.sets(for: engine.exercises[0]).count, 1)
        XCTAssertEqual(engine.nextSetIndex(for: engine.exercises[0]), 2)
    }

    func testUndoOnEmptyDoesNothing() {
        var engine = WorkoutSessionEngine(exercises: [exercise("卧推")], startedAt: t0)
        engine.undoSet(for: engine.exercises[0])
        XCTAssertTrue(engine.completed.isEmpty)
    }

    // MARK: - 汇总

    func testSummaryCounts() {
        let a = exercise("卧推", sets: 2)
        let b = exercise("划船", sets: 1)
        var engine = WorkoutSessionEngine(exercises: [a, b], startedAt: t0)

        engine.completeSet(weightKg: 60, reps: 10, at: t0)   // 600
        engine.completeSet(weightKg: 60, reps: 10, at: t0)   // 600
        engine.moveTo(index: 1)
        engine.completeSet(weightKg: 40, reps: 12, at: t0)   // 480

        let summary = engine.summary(at: t0.addingTimeInterval(1_500))
        XCTAssertEqual(summary.exerciseCount, 2)
        XCTAssertEqual(summary.setCount, 3)
        XCTAssertEqual(summary.totalVolumeKg, 1_680, accuracy: 0.001)
        XCTAssertEqual(summary.duration, 1_500, accuracy: 0.001)
    }

    func testSummaryWithNoSets() {
        let engine = WorkoutSessionEngine(exercises: [exercise("卧推")], startedAt: t0)
        let summary = engine.summary(at: t0.addingTimeInterval(60))
        XCTAssertEqual(summary.exerciseCount, 0)
        XCTAssertEqual(summary.setCount, 0)
        XCTAssertEqual(summary.totalVolumeKg, 0)
    }

    func testIsFinished() {
        var engine = WorkoutSessionEngine(exercises: [exercise("卧推", sets: 1)], startedAt: t0)
        XCTAssertFalse(engine.isFinished)
        engine.completeSet(weightKg: 60, reps: 10, at: t0)
        XCTAssertTrue(engine.isFinished)
    }

    // MARK: - 边界

    func testEmptyExercises() {
        var engine = WorkoutSessionEngine(exercises: [], startedAt: t0)
        XCTAssertNil(engine.currentExercise)
        XCTAssertFalse(engine.completeSet(weightKg: 60, reps: 10, at: t0))
        XCTAssertFalse(engine.isFinished, "没有动作不算「练完了」")
        engine.advanceToNextUnfinished()
        XCTAssertEqual(engine.currentIndex, 0)
    }

    func testCurrentIndexClampedOnInit() {
        let engine = WorkoutSessionEngine(
            exercises: [exercise("卧推")], startedAt: t0, currentIndex: 99
        )
        XCTAssertEqual(engine.currentIndex, 0)
    }
}
