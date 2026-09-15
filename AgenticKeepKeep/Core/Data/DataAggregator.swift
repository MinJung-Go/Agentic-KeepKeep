import Foundation
import SwiftData

/// 把本地记录聚合成分析摘要。
/// 这是隐私边界：只有聚合结果会离开设备，原始记录不出本机。
@MainActor
enum DataAggregator {

    /// 生成指定区间的分析摘要
    static func digest(days: Int = 7, endingAt end: Date = .now, context: ModelContext) throws -> AnalysisDigest {
        let calendar = Calendar.current
        let endOfToday = calendar.startOfDay(for: end).addingTimeInterval(86_400)
        let startDate = calendar.date(byAdding: .day, value: -(max(days, 1) - 1),
                                      to: calendar.startOfDay(for: end)) ?? calendar.startOfDay(for: end)

        var digest = AnalysisDigest(periodStart: startDate, periodEnd: endOfToday)

        // 训练
        let sessionDescriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.date >= startDate && $0.date < endOfToday },
            sortBy: [SortDescriptor(\.date)]
        )
        let sessions = try context.fetch(sessionDescriptor)
        digest.workoutCount = sessions.count
        digest.totalVolumeKg = sessions.reduce(0) { $0 + $1.totalVolumeKg }
        digest.trends = buildTrends(sessions: sessions, now: endOfToday)

        // 饮食
        let mealDescriptor = FetchDescriptor<MealEntry>(
            predicate: #Predicate { $0.date >= startDate && $0.date < endOfToday },
            sortBy: [SortDescriptor(\.date)]
        )
        let meals = try context.fetch(mealDescriptor)
        digest.nutrition = buildNutrition(meals: meals)

        // 健康快照
        let snapshotDescriptor = FetchDescriptor<HealthSnapshot>(
            predicate: #Predicate { $0.day >= startDate && $0.day < endOfToday },
            sortBy: [SortDescriptor(\.day)]
        )
        let snapshots = try context.fetch(snapshotDescriptor)
        if !snapshots.isEmpty {
            let sleeps = snapshots.map(\.sleepHours).filter { $0 > 0 }
            if !sleeps.isEmpty {
                digest.sleepAvgHours = sleeps.reduce(0, +) / Double(sleeps.count)
                digest.sleepMinHours = sleeps.min() ?? 0
            }
            let hrvs = snapshots.map(\.hrvMs).filter { $0 > 0 }
            if !hrvs.isEmpty {
                digest.hrvAvg = hrvs.reduce(0, +) / Double(hrvs.count)
            }
            let heartRates = snapshots.map(\.restingHeartRate).filter { $0 > 0 }
            if !heartRates.isEmpty {
                digest.restingHeartRateAvg = heartRates.reduce(0, +) / Double(heartRates.count)
            }
            let steps = snapshots.map(\.steps).filter { $0 > 0 }
            if !steps.isEmpty {
                digest.stepsAvgPerDay = steps.reduce(0, +) / steps.count
            }
        }

        let healthWorkouts = try context.fetch(FetchDescriptor<HealthWorkout>(
            predicate: #Predicate { $0.date >= startDate && $0.date <= end }
        ))
        let energies = snapshots.map(\.activeEnergyKcal).filter { $0.isFinite && $0 > 0 }
        digest.healthActivity = HealthActivityDigest(
            workoutCount: healthWorkouts.count,
            totalMinutes: healthWorkouts.map(\.durationMinutes).filter { $0.isFinite && $0 > 0 }.reduce(0, +),
            distanceKm: healthWorkouts.compactMap(\.distanceKm).filter { $0.isFinite && $0 > 0 }.reduce(0, +),
            distanceRecords: healthWorkouts.compactMap(\.distanceKm).filter { $0.isFinite && $0 > 0 }.count,
            energyAverageKcal: energies.isEmpty ? 0 : energies.reduce(0, +) / Double(energies.count),
            energyDays: energies.count
        )

        return digest
    }

    /// 供教练对话使用的精简摘要（比报告摘要更短）
    static func recentSummary(days: Int = 14, context: ModelContext) throws -> String {
        let digest = try digest(days: days, context: context)
        var parts: [String] = []

        parts.append("Moveliq 内记录：近 \(days) 天训练 \(digest.workoutCount) 次（不含 Apple 健康导入，健康运动见个人概况）")

        if digest.sleepAvgHours > 0 {
            parts.append(String(format: "日均睡眠 %.1fh", digest.sleepAvgHours))
        }
        if let stalled = digest.trends.first(where: { $0.stalledWeeks >= 2 }) {
            parts.append("\(stalled.name) 停滞 \(stalled.stalledWeeks) 周")
        }
        if digest.nutrition.daysLogged > 0 {
            parts.append("日均蛋白 \(Int(digest.nutrition.avgProteinG.rounded()))g")
        }

        return parts.joined(separator: "，")
    }

    // MARK: - 内部

    private struct SetPoint {
        let date: Date
        let e1RM: Double
    }

    private static func buildTrends(sessions: [WorkoutSession], now: Date) -> [ExerciseTrend] {
        var grouped: [String: [SetPoint]] = [:]

        for session in sessions {
            for set in session.sets where set.weightKg > 0 && set.reps > 0 {
                grouped[set.exerciseName, default: []].append(
                    SetPoint(date: session.date, e1RM: set.estimatedOneRepMax)
                )
            }
        }

        var trends: [ExerciseTrend] = []
        for (name, points) in grouped {
            let sorted = points.sorted { $0.date < $1.date }
            guard let best = sorted.max(by: { $0.e1RM < $1.e1RM }) else { continue }
            let recent = sorted.last?.e1RM ?? 0

            let weeksSinceBest = Int(now.timeIntervalSince(best.date) / (7 * 86_400))
            var trend = ExerciseTrend(
                name: name,
                sessions: Set(sorted.map { Calendar.current.startOfDay(for: $0.date) }).count,
                bestE1RM: best.e1RM,
                recentE1RM: recent,
                stalledWeeks: max(0, weeksSinceBest)
            )
            // 最近一次已接近或刷新最佳成绩 → 不算停滞
            if best.e1RM > 0 && recent >= best.e1RM * 0.98 {
                trend.stalledWeeks = 0
            }
            trends.append(trend)
        }

        // 容量大的动作排前面，便于模型关注主要动作
        return trends.sorted { $0.bestE1RM > $1.bestE1RM }
    }

    private static func buildNutrition(meals: [MealEntry]) -> NutritionDigest {
        guard !meals.isEmpty else { return NutritionDigest() }

        let calendar = Calendar.current
        let days = Set(meals.map { calendar.startOfDay(for: $0.date) })

        var digest = NutritionDigest()
        digest.daysLogged = days.count

        // 按「记录到的天数」取日均，避免未记录日拉低平均值
        let totalCalories = meals.reduce(0) { $0 + $1.totalCalories }
        let totalProtein = meals.reduce(0) { $0 + $1.totalProteinG }
        let totalCarbs = meals.reduce(0) { $0 + $1.totalCarbsG }
        let totalFat = meals.reduce(0) { $0 + $1.totalFatG }

        let divisor = Double(max(1, days.count))
        digest.avgCalories = totalCalories / divisor
        digest.avgProteinG = totalProtein / divisor
        digest.avgCarbsG = totalCarbs / divisor
        digest.avgFatG = totalFat / divisor

        return digest
    }
}
