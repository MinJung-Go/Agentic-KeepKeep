import Foundation

/// 饮食分析：日均热量与宏营养素，以及和目标的差距。
/// 纯计算，便于单测；不依赖 SwiftData。
struct NutritionAnalysis: Equatable {

    var daysLogged: Int = 0
    var daysInRange: Int = 0
    var avgCalories: Double = 0
    var avgProteinG: Double = 0
    var avgCarbsG: Double = 0
    var avgFatG: Double = 0

    /// 最近一次体重（用于推算蛋白质目标）
    var latestWeightKg: Double?
    /// 蛋白质目标：1.6 g/kg（增肌/减脂通用区间下限）
    var proteinTargetG: Double?
    var proteinGapG: Double?

    var hasData: Bool { daysLogged > 0 }

    var loggingCoverage: Double {
        guard daysInRange > 0 else { return 0 }
        return Double(daysLogged) / Double(daysInRange)
    }

    /// 一句话结论
    var insight: String {
        guard hasData else { return "这段时间还没有饮食记录。" }

        var parts: [String] = []

        if let target = proteinTargetG, let gap = proteinGapG {
            if gap > 10 {
                parts.append("蛋白质日均 \(Format.number(avgProteinG))g，距离目标 \(Format.number(target))g 还差 \(Format.number(gap))g")
            } else {
                parts.append("蛋白质摄入已达目标（日均 \(Format.number(avgProteinG))g）")
            }
        } else {
            parts.append("蛋白质日均 \(Format.number(avgProteinG))g")
        }

        if loggingCoverage < 0.5 {
            parts.append("记录天数偏少（\(daysLogged)/\(daysInRange) 天），结论仅供参考")
        }

        return parts.joined(separator: "；") + "。"
    }

    static func build(
        meals: [MealEntry],
        latestWeightKg: Double?,
        daysInRange: Int
    ) -> NutritionAnalysis {
        var analysis = NutritionAnalysis()
        analysis.daysInRange = daysInRange
        analysis.latestWeightKg = latestWeightKg

        guard !meals.isEmpty else { return analysis }

        let calendar = Calendar.current
        let days = Set(meals.map { calendar.startOfDay(for: $0.date) })
        analysis.daysLogged = days.count

        let divisor = Double(max(1, days.count))
        analysis.avgCalories = meals.reduce(0) { $0 + $1.totalCalories } / divisor
        analysis.avgProteinG = meals.reduce(0) { $0 + $1.totalProteinG } / divisor
        analysis.avgCarbsG = meals.reduce(0) { $0 + $1.totalCarbsG } / divisor
        analysis.avgFatG = meals.reduce(0) { $0 + $1.totalFatG } / divisor

        if let weight = latestWeightKg, weight > 0 {
            let target = weight * 1.6
            analysis.proteinTargetG = target
            analysis.proteinGapG = max(0, target - analysis.avgProteinG)
        }

        return analysis
    }
}
