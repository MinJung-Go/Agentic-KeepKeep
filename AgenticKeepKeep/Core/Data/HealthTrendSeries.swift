import Foundation

/// 缺失值不补零；单点也可以显示。各入口共用同一日期窗口与筛选规则。
struct HealthTrendSeries: Identifiable {
    struct Point: Identifiable {
        var id: Date { day }
        let day: Date
        let value: Double
    }
    enum Metric: String { case steps, energy, minutes, count, hrv, heartRate }
    var id: String { metric.rawValue }
    let metric: Metric
    let title: String
    let unit: String
    let points: [Point]

    @MainActor
    static func build(snapshots: [HealthSnapshot], workouts: [HealthWorkout],
                      days: Int, now: Date = .now) -> [HealthTrendSeries] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today) ?? today
        let samples = snapshots.filter { $0.day >= start && $0.day <= today }
        let definitions: [(Metric, String, String, (HealthSnapshot) -> Double)] = [
            (.steps, "每日步数", "步", { Double($0.steps) }),
            (.energy, "每日活动能量", "kcal", { $0.activeEnergyKcal }),
            (.hrv, "心率变异性", "ms", { $0.hrvMs }),
            (.heartRate, "静息心率", "bpm", { $0.restingHeartRate })
        ]
        var series = definitions.compactMap { metric, title, unit, value -> HealthTrendSeries? in
            let points = samples.compactMap { sample -> Point? in
                let number = value(sample)
                guard number.isFinite, number > 0 else { return nil }
                return Point(day: sample.day, value: number)
            }.sorted { $0.day < $1.day }
            guard !points.isEmpty else { return nil }
            return HealthTrendSeries(metric: metric, title: title, unit: unit, points: points)
        }
        let recent = workouts.filter { $0.date >= start && $0.date <= now }
        let grouped = Dictionary(grouping: recent) { calendar.startOfDay(for: $0.date) }
        if !grouped.isEmpty {
            let count = grouped.map { Point(day: $0.key, value: Double($0.value.count)) }.sorted { $0.day < $1.day }
            series.append(HealthTrendSeries(metric: .count, title: "健康运动次数", unit: "次", points: count))
            let minutes = grouped.compactMap { day, records -> Point? in
                let values = records.map(\.durationMinutes).filter { $0.isFinite && $0 > 0 }
                guard !values.isEmpty else { return nil }
                return Point(day: day, value: values.reduce(0, +))
            }.sorted { $0.day < $1.day }
            if !minutes.isEmpty {
                series.append(HealthTrendSeries(metric: .minutes, title: "健康运动时长", unit: "分钟", points: minutes))
            }
        }
        return series
    }
}
