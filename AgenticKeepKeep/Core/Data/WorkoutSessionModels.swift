import Foundation
import SwiftData

/// 实际完成的一组。
///
/// 与 `ExerciseSet` 的分工：
/// - `ExerciseSet` 是记录里的**动作行**（「杠铃卧推 80kg × 8 次 × 5 组」），给聚合与展示用
/// - `SetLog` 是**逐组的实情**（第 3 组做了 75kg、第 5 组只做了 6 次）
///
/// 只记「做了几组」的话，第 4 组减重这类情况就丢了，日后想补还得再改一次模型。
@Model
final class SetLog {

    var uuid: UUID = UUID()
    /// 属于计划里的哪个动作（`PlanExercise.uuid`）。
    /// 训练进行中还没有 `ExerciseSet`，只能靠这个 UUID 归类 —— 所以它是必填语义。
    var exerciseUUID: UUID?
    /// 第几组，从 1 开始
    var setIndex: Int = 1
    var weightKg: Double = 0
    var reps: Int = 0
    var completedAt: Date = Date()

    /// 训练进行中：挂在草稿上
    var draft: WorkoutSessionDraft?
    /// 练完之后：挂到正式记录的动作行上
    var exerciseSet: ExerciseSet?

    init(
        exerciseUUID: UUID?,
        setIndex: Int,
        weightKg: Double,
        reps: Int,
        completedAt: Date = .now
    ) {
        self.exerciseUUID = exerciseUUID
        self.setIndex = setIndex
        self.weightKg = weightKg
        self.reps = reps
        self.completedAt = completedAt
    }

    /// 本组容量
    var volumeKg: Double { weightKg * Double(reps) }
}

/// 进行中的训练会话。
///
/// 存在的理由是**中断恢复**：健身房里锁屏、切音乐、接电话都很常见，
/// 状态只存内存的话回来就白练了。练完转成正式记录并删除本条目。
@Model
final class WorkoutSessionDraft {

    var uuid: UUID = UUID()
    /// 对应的训练日。存 UUID 而不是关系 —— 草稿是临时的，
    /// 不该把计划日的级联删除规则牵连进来（计划被删不该顺手删掉进行中的训练）
    var planDayUUID: UUID?
    /// 训练日标题的快照：进行中计划被改，这次训练的名字也不该跟着变
    var title: String = ""
    var startedAt: Date = Date()
    /// 当前停在哪个动作（`PlanExercise` 的序号）
    var currentIndex: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \SetLog.draft)
    var logs: [SetLog] = []

    init(planDayUUID: UUID?, title: String, startedAt: Date = .now) {
        self.planDayUUID = planDayUUID
        self.title = title
        self.startedAt = startedAt
    }

    /// 某个动作已完成的所有组。
    /// 按 `exerciseUUID` 筛而不是 `exerciseSet?.uuid` —— 进行中还没有 `ExerciseSet`。
    func logs(for exerciseUUID: UUID) -> [SetLog] {
        logs.filter { $0.exerciseUUID == exerciseUUID }
            .sorted { $0.setIndex < $1.setIndex }
    }

    var completedSetCount: Int { logs.count }
}

/// 组次文案的解析。
///
/// 计划里的 `setsText` 是人写的（「4×10」「5x5」「4 组 × 10 次」），
/// 解析不出来就返回 nil —— **不编造组次**，让界面显示原文。
enum SetSpecParser {

    /// 支持 `4×10` / `4x10` / `4*10` / `4 组 × 10 次` / `4×10次`
    ///
    /// 先把空白与「组 / 次」这两个量词去掉，**再**按分隔符切。
    /// 顺序不能反：若先把「组」换成「×」，「4 组 × 10 次」会多切出一段变成三个部分。
    static func parse(_ text: String) -> (sets: Int, reps: Int)? {
        var normalized = String(text.lowercased().filter { !$0.isWhitespace })
        normalized = normalized
            .replacingOccurrences(of: "组", with: "")
            .replacingOccurrences(of: "次", with: "")
            .replacingOccurrences(of: "*", with: "×")
            .replacingOccurrences(of: "x", with: "×")

        let parts = normalized.split(separator: "×", omittingEmptySubsequences: true)

        guard parts.count == 2,
              let sets = Int(parts[0]),
              let reps = Int(parts[1]),
              sets > 0, reps > 0
        else { return nil }

        return (sets, reps)
    }
}
