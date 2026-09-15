import SwiftData
import XCTest
@testable import AgenticKeepKeep

/// 对话式记录的多轮上下文压缩
@MainActor
final class LoggingHistoryTests: XCTestCase {

    private func userTurn(_ text: String) -> LoggingViewModel.LogTurn {
        LoggingViewModel.LogTurn(kind: .user, text: text)
    }

    private func assistantTurn(drafts: [LogDraft]) -> LoggingViewModel.LogTurn {
        LoggingViewModel.LogTurn(kind: .assistant, drafts: drafts)
    }

    func testWorkoutSummaryLine() {
        var draft = LogDraft(kind: .workout)
        draft.workout.exercises[0].name = "深蹲"
        draft.workout.exercises[0].weightText = "100"
        draft.workout.exercises[0].repsText = "5"
        draft.workout.exercises[0].setsText = "5"

        let line = LoggingViewModel.summaryLine(for: draft)

        XCTAssertEqual(line, "训练 深蹲 100kg ×5次 5组")
    }

    func testWorkoutSummarySkipsIncompleteRows() {
        var draft = LogDraft(kind: .workout)
        draft.workout.exercises[0].name = "卧推"
        draft.workout.exercises.append(ExerciseDraft())   // 空行

        let line = LoggingViewModel.summaryLine(for: draft)

        XCTAssertEqual(line, "训练 卧推")
    }

    func testMealSummaryLine() {
        var draft = LogDraft(kind: .meal)
        draft.meal.items[0].name = "牛肉面"
        draft.meal.items.append(FoodDraft())
        draft.meal.items[1].name = "豆浆"

        XCTAssertEqual(LoggingViewModel.summaryLine(for: draft), "饮食 牛肉面、豆浆")
    }

    func testMetricAndNoteSummary() {
        var metric = LogDraft(kind: .metric)
        metric.metric.kind = .weight
        metric.metric.valueText = "74.5"
        XCTAssertEqual(LoggingViewModel.summaryLine(for: metric), "体重 74.5kg")

        var note = LogDraft(kind: .note)
        note.note.text = "昨晚没睡好"
        XCTAssertEqual(LoggingViewModel.summaryLine(for: note), "笔记：昨晚没睡好")
    }

    func testHistoryKeepsUserWordsAndAssistantSummary() {
        var draft = LogDraft(kind: .workout)
        draft.workout.exercises[0].name = "深蹲"
        draft.workout.exercises[0].weightText = "100"
        draft.workout.exercises[0].repsText = "5"
        draft.workout.exercises[0].setsText = "5"

        let history = LoggingViewModel.historyTurns(from: [
            userTurn("深蹲100kg 5×5"),
            assistantTurn(drafts: [draft])
        ])

        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].role, .user)
        XCTAssertEqual(history[0].content, "深蹲100kg 5×5")
        XCTAssertEqual(history[1].role, .assistant)
        XCTAssertTrue(history[1].content.contains("深蹲 100kg"))
        XCTAssertTrue(history[1].content.contains("已解析"))
    }

    func testHistorySkipsFailures() {
        let history = LoggingViewModel.historyTurns(from: [
            LoggingViewModel.LogTurn(kind: .failure, text: "网络不可用")
        ])

        XCTAssertTrue(history.isEmpty, "失败消息不需要作为解析上下文")
    }

    func testHistorySkipsEmptyAssistantTurns() {
        let history = LoggingViewModel.historyTurns(from: [
            assistantTurn(drafts: [LogDraft(kind: .workout)])   // 空草稿
        ])

        XCTAssertTrue(history.isEmpty)
    }

    func testMultiTurnFollowUpKeepsPriorContext() {
        var first = LogDraft(kind: .workout)
        first.workout.exercises[0].name = "深蹲"
        first.workout.exercises[0].weightText = "100"
        first.workout.exercises[0].repsText = "5"
        first.workout.exercises[0].setsText = "5"

        let history = LoggingViewModel.historyTurns(from: [
            userTurn("深蹲100kg 5×5"),
            assistantTurn(drafts: [first]),
            userTurn("再加一组")
        ])

        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.last?.content, "再加一组")
        XCTAssertTrue(history[1].content.contains("5组"), "上下文里要有上一轮组数，模型才能理解「再加一组」")
    }

    // MARK: - 保存状态

    func testSaveMarksTurnAndReturnsCount() throws {
        let context = ModelContext(try AppModelContainer.inMemory())
        let viewModel = LoggingViewModel()

        var draft = LogDraft(kind: .workout)
        draft.workout.exercises[0].name = "深蹲"
        draft.workout.exercises[0].weightText = "100"
        draft.workout.exercises[0].repsText = "5"
        draft.workout.exercises[0].setsText = "5"

        let turn = LoggingViewModel.LogTurn(kind: .assistant, drafts: [draft])
        viewModel.turns = [turn]

        let saved = viewModel.save(turnID: turn.id, context: context)

        XCTAssertEqual(saved, 1)
        XCTAssertEqual(viewModel.turns.first?.savedCount, 1)
        XCTAssertTrue(viewModel.turns.first?.isSaved ?? false)
        XCTAssertEqual(viewModel.save(turnID: turn.id, context: context), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutSession>()), 1)
    }

    func testCancelConfirmationDoesNotSaveWorkout() throws {
        let context = ModelContext(try AppModelContainer.inMemory())
        let viewModel = LoggingViewModel()
        var draft = LogDraft(kind: .workout)
        draft.workout.exercises[0].name = "卧推"
        viewModel.turns = [.init(kind: .assistant, drafts: [draft])]
        viewModel.reset()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutSession>()), 0)
        XCTAssertTrue(viewModel.turns.isEmpty)
    }

    func testSaveIgnoresEmptyDrafts() throws {
        let context = ModelContext(try AppModelContainer.inMemory())
        let viewModel = LoggingViewModel()

        let turn = LoggingViewModel.LogTurn(kind: .assistant, drafts: [LogDraft(kind: .workout)])
        viewModel.turns = [turn]

        XCTAssertEqual(viewModel.save(turnID: turn.id, context: context), 0)
        XCTAssertNil(viewModel.turns.first?.savedCount, "空草稿不应标记为已保存")
    }

    func testResetClearsConversation() {
        let viewModel = LoggingViewModel()
        viewModel.turns = [userTurn("深蹲100kg")]
        viewModel.inputText = "待发送"

        viewModel.reset()

        XCTAssertTrue(viewModel.turns.isEmpty)
        XCTAssertTrue(viewModel.inputText.isEmpty)
    }
}
