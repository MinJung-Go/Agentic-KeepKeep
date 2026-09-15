import Foundation

/// 训练会话的推进逻辑。
///
/// **纯值类型，不碰 SwiftData** —— 推进规则（下一组、下一个动作、跳过、多做少做、汇总）
/// 是这一轮最容易出错的地方，抽出来才能独立单测。
///
/// 视图只负责把它画出来、把点击转成方法调用。
struct WorkoutSessionEngine: Equatable {

    /// 计划里的一个动作
    struct Exercise: Identifiable, Equatable {
        let id: UUID
        let name: String
        /// 计划组数；`setsText` 解析不出来时是 nil
        let plannedSets: Int?
        let plannedReps: Int?
        let plannedWeightKg: Double?
        /// 计划原文（如「4×10」）。解析失败时界面显示它，不编造组次
        let setsText: String
    }

    /// 已完成的一组
    struct CompletedSet: Equatable {
        let exerciseID: UUID
        let setIndex: Int
        let weightKg: Double
        let reps: Int
        let completedAt: Date
    }

    struct Summary: Equatable {
        let duration: TimeInterval
        /// 至少完成了一组的动作数（不是计划里的动作数）
        let exerciseCount: Int
        let setCount: Int
        let totalVolumeKg: Double
    }

    let exercises: [Exercise]
    let startedAt: Date
    private(set) var completed: [CompletedSet]
    private(set) var currentIndex: Int

    init(
        exercises: [Exercise],
        startedAt: Date = .now,
        completed: [CompletedSet] = [],
        currentIndex: Int = 0
    ) {
        self.exercises = exercises
        self.startedAt = startedAt
        self.completed = completed
        self.currentIndex = exercises.isEmpty ? 0 : min(max(currentIndex, 0), exercises.count - 1)
    }

    // MARK: - 查询

    var currentExercise: Exercise? {
        exercises.indices.contains(currentIndex) ? exercises[currentIndex] : nil
    }

    func sets(for exercise: Exercise) -> [CompletedSet] {
        completed.filter { $0.exerciseID == exercise.id }.sorted { $0.setIndex < $1.setIndex }
    }

    /// 这个动作下一个该做第几组（从 1 开始）
    func nextSetIndex(for exercise: Exercise) -> Int {
        sets(for: exercise).count + 1
    }

    /// 计划组数做完就算完成。**解析不出组数时永远不算完成** ——
    /// 那说明计划里写的是别的格式，不该替用户决定「你做够了」
    func isExerciseFinished(_ exercise: Exercise) -> Bool {
        guard let planned = exercise.plannedSets else { return false }
        return sets(for: exercise).count >= planned
    }

    var isFinished: Bool {
        !exercises.isEmpty && exercises.allSatisfy { isExerciseFinished($0) }
    }

    var plannedSetCount: Int {
        exercises.reduce(0) { $0 + ($1.plannedSets ?? 0) }
    }

    // MARK: - 推进

    /// 勾掉当前动作的下一组。返回 true 表示这个动作做完了（可以切下一个）
    @discardableResult
    mutating func completeSet(weightKg: Double, reps: Int, at date: Date = .now) -> Bool {
        guard let exercise = currentExercise else { return false }

        completed.append(CompletedSet(
            exerciseID: exercise.id,
            setIndex: nextSetIndex(for: exercise),
            weightKg: weightKg,
            reps: reps,
            completedAt: date
        ))

        return isExerciseFinished(exercise)
    }

    /// 撤回某组的勾（点错了）
    mutating func undoSet(for exercise: Exercise) {
        guard let last = sets(for: exercise).last else { return }
        completed.removeAll { $0.exerciseID == last.exerciseID && $0.setIndex == last.setIndex }
    }

    /// 前进到下一个还没做完的动作。
    /// 先往后找，后面没有了再回头找 —— **不绕回开头**，那种「循环」会让人以为漏了什么。
    mutating func advanceToNextUnfinished() {
        guard !exercises.isEmpty else { return }

        if let next = exercises.indices.first(where: { $0 > currentIndex && !isExerciseFinished(exercises[$0]) }) {
            currentIndex = next
            return
        }
        if let previous = exercises.indices.last(where: { $0 < currentIndex && !isExerciseFinished(exercises[$0]) }) {
            currentIndex = previous
        }
    }

    mutating func moveTo(index: Int) {
        guard exercises.indices.contains(index) else { return }
        currentIndex = index
    }

    // MARK: - 汇总

    func summary(at date: Date = .now) -> Summary {
        Summary(
            duration: max(0, date.timeIntervalSince(startedAt)),
            exerciseCount: Set(completed.map(\.exerciseID)).count,
            setCount: completed.count,
            totalVolumeKg: completed.reduce(0) { $0 + $1.weightKg * Double($1.reps) }
        )
    }
}
