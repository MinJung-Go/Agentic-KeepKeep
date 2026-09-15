import Foundation
import SwiftData

/// 把本地数据聚合成教练可用的「个人概况」。
/// 隐私边界：这里产出的都是聚合结果，逐条原始记录不会离开设备。
@MainActor
enum CoachContextBuilder {

    /// 默认回顾窗口（天）
    static let defaultDays = 28

    static func build(context: ModelContext, days: Int = defaultDays, now: Date = .now) throws -> CoachContext {
        var coachContext = CoachContext()
        coachContext.profileText = try profileText(context: context, days: days, now: now)
        coachContext.recentSummary = try DataAggregator.recentSummary(days: min(days, 14), context: context)
        return coachContext
    }

    /// 生成有界的聚合概况；运动类型只列前 3 类，不发送逐条健康记录。
    static func profileText(context: ModelContext, days: Int = defaultDays, now: Date = .now) throws -> String {
        let digest = try DataAggregator.digest(days: days, endingAt: now, context: context)
        var lines: [String] = []

        lines.append(trainingLine(digest: digest, days: days, context: context, now: now))
        lines.append(contentsOf: try healthLines(context: context, days: days, now: now))
        lines.append(contentsOf: digest.trends.prefix(5).map(trendLine))

        if let recovery = recoveryLine(digest: digest) {
            lines.append(recovery)
        }

        if let nutrition = nutritionLine(digest: digest, context: context) {
            lines.append(nutrition)
        }

        if let body = bodyLine(context: context, days: days, now: now) {
            lines.append(body)
        }

        if let plan = try planLine(context: context) {
            lines.append(plan)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - 各段

    private static func trainingLine(
        digest: AnalysisDigest,
        days: Int,
        context: ModelContext,
        now: Date
    ) -> String {
        var line = "【训练】Moveliq 内记录：近 \(days) 天 \(digest.workoutCount) 次，总容量 \(Int(digest.totalVolumeKg.rounded()))kg"

        if let last = try? newestWorkoutDate(context: context) {
            let calendar = Calendar.current
            let daysSince = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: last),
                to: calendar.startOfDay(for: now)
            ).day ?? 0

            switch daysSince {
            case ..<0: break
            case 0: line += "；最近一次是今天"
            case 1: line += "；最近一次是昨天"
            default: line += "；最近一次在 \(daysSince) 天前"
            }
        }

        return line
    }

    /// 仅汇总已同步的健康数据，和手动训练分开呈现，避免重复计算。
    private static func healthLines(context: ModelContext, days: Int, now: Date) throws -> [String] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? today
        let workouts = try context.fetch(FetchDescriptor<HealthWorkout>(
            predicate: #Predicate { $0.date >= start && $0.date <= now },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        ))
        let snapshots = try context.fetch(FetchDescriptor<HealthSnapshot>(
            predicate: #Predicate { $0.day >= start && $0.day <= today }
        ))
        var lines: [String] = []
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        var current: [String] = []
        if let snapshot = snapshots.first(where: { calendar.isDate($0.day, inSameDayAs: today) }) {
            current.append(snapshot.steps > 0 ? "今天步数 \(snapshot.steps) 步" : "今天暂无可用步数")
            if snapshot.activeEnergyKcal.isFinite, snapshot.activeEnergyKcal > 0 {
                current.append("今天活动能量 \(format(snapshot.activeEnergyKcal))kcal")
            }
            current.append("健康快照更新于 \(dateFormatter.string(from: snapshot.updatedAt))，并非实时读数")
        } else {
            current.append("今天尚无已同步的健康快照，不能用近期日均值代替今天的数据")
        }
        let todayWorkouts = workouts.filter { calendar.isDate($0.date, inSameDayAs: today) }
        if !todayWorkouts.isEmpty {
            let minutes = todayWorkouts.map(\.durationMinutes).filter { $0.isFinite && $0 > 0 }.reduce(0, +)
            current.append("今天已同步训练 \(todayWorkouts.count) 次、\(format(minutes)) 分钟")
        } else {
            current.append("今天没有已同步训练记录，不代表没有运动")
        }
        lines.append("【今日 Apple 健康】\(dateFormatter.string(from: now))：" + current.joined(separator: "；"))
        if workouts.isEmpty {
            lines.append("【Apple 健康运动】近 \(days) 天没有已同步的训练记录；不代表没有运动或未授权。")
        } else {
            let minutes = workouts.map(\.durationMinutes).filter { $0.isFinite && $0 > 0 }.reduce(0, +)
            let distances = workouts.compactMap(\.distanceKm).filter { $0.isFinite && $0 > 0 }
            var line = "【Apple 健康运动】近 \(days) 天已同步 \(workouts.count) 次，累计 \(format(minutes)) 分钟"
            if !distances.isEmpty {
                line += "；已记录距离合计 \(format(distances.reduce(0, +)))km（\(distances.count) 次有距离）"
            }
            let groups = Dictionary(grouping: workouts, by: \.activityName)
            let types = groups.keys.sorted {
                let lhs = groups[$0]!.count, rhs = groups[$1]!.count
                return lhs == rhs ? $0 < $1 : lhs > rhs
            }.prefix(3).map { name in
                "\(String(name.prefix(24))) \(groups[name]!.count) 次"
            }
            line += "；主要类型：" + types.joined(separator: "、")
            if let latest = workouts.first {
                let elapsed = calendar.dateComponents([.day], from: calendar.startOfDay(for: latest.date), to: today).day ?? 0
                line += "；最近一次距今 \(elapsed) 天"
            }
            lines.append(line)
        }
        var activity: [String] = []
        // 现有模型用 0 表示缺失；不能把缺失日算作零活动。
        let steps = snapshots.map(\.steps).filter { $0 > 0 }.map(Double.init)
        if !steps.isEmpty {
            activity.append("日均步数 \(format((steps.reduce(0, +) / Double(steps.count)).rounded()))（\(steps.count) 天有值）")
        }
        let energy = snapshots.map(\.activeEnergyKcal).filter { $0.isFinite && $0 > 0 }
        if !energy.isEmpty {
            activity.append("日均活动能量 \(format((energy.reduce(0, +) / Double(energy.count)).rounded()))kcal（\(energy.count) 天有值，非单次训练消耗）")
        }
        if !activity.isEmpty {
            lines.append("【Apple 健康活动】近 \(days) 天：" + activity.joined(separator: "；"))
        }
        return lines
    }

    private static func trendLine(_ trend: ExerciseTrend) -> String {
        var line = "- \(trend.name)：\(trend.sessions) 次，最佳估算 1RM \(Int(trend.bestE1RM.rounded()))kg"
        if trend.recentE1RM > 0 {
            line += "，最近 \(Int(trend.recentE1RM.rounded()))kg"
        }
        if trend.stalledWeeks >= 2 {
            line += "，已停滞 \(trend.stalledWeeks) 周"
        }
        return line
    }

    private static func recoveryLine(digest: AnalysisDigest) -> String? {
        var parts: [String] = []

        if digest.sleepAvgHours > 0 {
            parts.append("日均睡眠 \(format(digest.sleepAvgHours))h（最低 \(format(digest.sleepMinHours))h）")
        }
        if digest.hrvAvg > 0 {
            parts.append("HRV 日均 \(Int(digest.hrvAvg.rounded()))ms")
        }
        if digest.restingHeartRateAvg > 0 {
            parts.append("静息心率 \(Int(digest.restingHeartRateAvg.rounded()))bpm")
        }

        guard !parts.isEmpty else { return nil }
        return "【恢复】" + parts.joined(separator: "；")
    }

    private static func nutritionLine(digest: AnalysisDigest, context: ModelContext) -> String? {
        let nutrition = digest.nutrition
        guard nutrition.daysLogged > 0 else { return nil }

        var line = "【饮食】记录 \(nutrition.daysLogged) 天，日均 \(Int(nutrition.avgCalories.rounded()))kcal，"
        line += "蛋白质 \(Int(nutrition.avgProteinG.rounded()))g"

        if let target = proteinTarget(context: context) {
            let gap = max(0, target - nutrition.avgProteinG)
            line += "（目标 \(Int(target.rounded()))g"
            line += gap > 5 ? "，差 \(Int(gap.rounded()))g）" : "，已达标）"
        }

        line += "，碳水 \(Int(nutrition.avgCarbsG.rounded()))g，脂肪 \(Int(nutrition.avgFatG.rounded()))g"
        return line
    }

    private static func bodyLine(context: ModelContext, days: Int, now: Date) -> String? {
        guard let weight = try? weightMetrics(context: context, days: days, now: now), !weight.isEmpty else {
            return nil
        }
        guard let latest = weight.last else { return nil }

        var line = "【身体】体重 \(format(latest.value))kg"

        if let first = weight.first, weight.count > 1 {
            let delta = latest.value - first.value
            let sign = delta >= 0 ? "+" : "−"
            line += "（\(format(first.value)) → \(format(latest.value))，\(sign)\(format(abs(delta)))kg）"
        }

        return line
    }

    private static func planLine(context: ModelContext) throws -> String? {
        let plans = try context.fetch(FetchDescriptor<Plan>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        ))
        guard let plan = plans.first(where: { $0.isActive }) ?? plans.first else { return nil }

        return "【课程表】《\(plan.title)》进行中，已完成 \(plan.completedCount)/\(plan.days.count)"
    }

    // MARK: - 查询

    private static func newestWorkoutDate(context: ModelContext) throws -> Date? {
        var descriptor = FetchDescriptor<WorkoutSession>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.date
    }

    private static func weightMetrics(context: ModelContext, days: Int, now: Date) throws -> [BodyMetric] {
        let since = Calendar.current.startOfDay(for: now).addingTimeInterval(-Double(days) * 86_400)
        return try context.fetch(FetchDescriptor<BodyMetric>(
            predicate: #Predicate { $0.kindRaw == "weight" && $0.date >= since },
            sortBy: [SortDescriptor(\.date)]
        ))
    }

    /// 蛋白质目标：最近一次体重 × 1.6 g/kg
    private static func proteinTarget(context: ModelContext) -> Double? {
        var descriptor = FetchDescriptor<BodyMetric>(
            predicate: #Predicate { $0.kindRaw == "weight" },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        guard let weight = try? context.fetch(descriptor).first?.value, weight > 0 else { return nil }
        return weight * 1.6
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
