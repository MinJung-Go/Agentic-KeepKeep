import Charts
import SwiftUI
import SwiftData

/// 趋势图表：体重 / 主要动作估算 1RM / 每周训练量 / 睡眠
///
/// 配色与形态全部取自 `ChartColor` 与设计系统 §9 —— 一张图最多三个色相、
/// 多序列用同色相深浅、目标线用灰色虚线、**不用渐变**。
struct TrendsView: View {

    @Query(sort: [SortDescriptor(\WorkoutSession.date)])
    private var workouts: [WorkoutSession]
    @Query(sort: [SortDescriptor(\BodyMetric.date)])
    private var metrics: [BodyMetric]
    @Query(sort: [SortDescriptor(\HealthSnapshot.day)])
    private var snapshots: [HealthSnapshot]

    @Query private var healthWorkouts: [HealthWorkout]

    private var healthSeries: [HealthTrendSeries] {
        HealthTrendSeries.build(snapshots: snapshots, workouts: healthWorkouts, days: days)
    }

    @State private var days = 90
    @State private var selectedExercise = ""

    private var rangeStart: Date {
        Calendar.current.startOfDay(for: .now).addingTimeInterval(-Double(days) * 86_400)
    }

    // MARK: - 数据准备

    private struct WeightPoint: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
    }

    private struct OneRMPoint: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
        let exercise: String
    }

    private struct VolumePoint: Identifiable {
        let id = UUID()
        let week: Date
        let volume: Double
    }

    private struct SleepPoint: Identifiable {
        let id = UUID()
        let day: Date
        let hours: Double
    }

    private var weightPoints: [WeightPoint] {
        metrics
            .filter { $0.kind == .weight && $0.date >= rangeStart }
            .map { WeightPoint(date: $0.date, value: $0.value) }
    }

    /// 训练次数最多的前 3 个动作 —— 再多就超过「一张图最多三个色相」
    private var trackedExercises: [String] {
        var counts: [String: Set<Date>] = [:]
        let calendar = Calendar.current

        for session in workouts where session.date >= rangeStart {
            for set in session.sets where set.weightKg > 0 && set.reps > 0 {
                counts[set.exerciseName, default: []].insert(calendar.startOfDay(for: session.date))
            }
        }

        return counts
            .sorted {
                if $0.value.count == $1.value.count { return $0.key < $1.key }
                return $0.value.count > $1.value.count
            }
            .prefix(3)
            .map(\.key)
    }

    private var oneRMPoints: [OneRMPoint] {
        let calendar = Calendar.current
        var bestPerSession: [String: [Date: Double]] = [:]

        for session in workouts where session.date >= rangeStart {
            for set in session.sets where set.weightKg > 0 && set.reps > 0 {
                let day = calendar.startOfDay(for: session.date)
                let current = bestPerSession[set.exerciseName]?[day] ?? 0
                bestPerSession[set.exerciseName, default: [:]][day] = max(current, set.estimatedOneRepMax)
            }
        }

        return trackedExercises.flatMap { name in
            (bestPerSession[name] ?? [:])
                .map { OneRMPoint(date: $0.key, value: $0.value, exercise: name) }
                .sorted { $0.date < $1.date }
        }
    }

    /// 同一色相的三档深浅，按「训练次数排名」分配
    private func seriesColor(_ exercise: String) -> Color {
        switch trackedExercises.firstIndex(of: exercise) {
        case 0: return ChartColor.training
        case 1: return ChartColor.training.opacity(ChartColor.medium)
        case 2: return ChartColor.training.opacity(ChartColor.faint)
        default: return ChartColor.baseline
        }
    }

    private var volumePerWeek: [VolumePoint] {
        let calendar = Calendar.current
        var buckets: [Date: Double] = [:]

        for session in workouts where session.date >= rangeStart {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: session.date)?.start else { continue }
            buckets[week, default: 0] += session.totalVolumeKg
        }

        return buckets
            .map { VolumePoint(week: $0.key, volume: $0.value) }
            .sorted { $0.week < $1.week }
    }

    private var sleepPoints: [SleepPoint] {
        snapshots
            .filter { $0.day >= rangeStart && $0.sleepHours > 0 }
            .map { SleepPoint(day: $0.day, hours: $0.sleepHours) }
    }

    private var sleepAverage: Double? {
        guard !sleepPoints.isEmpty else { return nil }
        return sleepPoints.reduce(0) { $0 + $1.hours } / Double(sleepPoints.count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                Picker("区间", selection: $days) {
                    Text("近 30 天").tag(30)
                    Text("近 90 天").tag(90)
                    Text("近 180 天").tag(180)
                }
                .pickerStyle(.segmented)

                ForEach(healthSeries) { series in
                    HealthTrendChart(series: series)
                }

                if weightPoints.count >= 2 {
                    weightChart
                }

                if !oneRMPoints.isEmpty {
                    oneRMChart
                }

                if !volumePerWeek.isEmpty {
                    volumeChart
                }

                if !sleepPoints.isEmpty {
                    sleepChart
                }

                if weightPoints.count < 2 && oneRMPoints.isEmpty && volumePerWeek.isEmpty && sleepPoints.isEmpty && healthSeries.isEmpty {
                    EmptyStateView(
                        symbol: "chart.line.uptrend.xyaxis",
                        tint: Theme.info,
                        title: "还没有足够数据",
                        message: "多记录几次训练、体重，或同步健康数据后就能看到趋势"
                    )
                }
            }
            .padding(Theme.Spacing.l)
        }
        .background(Theme.canvas)
        .navigationTitle("趋势")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 图

    private var weightChart: some View {
        chartCard(title: "体重", unit: "kg") {
            Chart(weightPoints) { point in
                AreaMark(
                    x: .value("日期", point.date),
                    y: .value("体重", point.value)
                )
                .foregroundStyle(ChartColor.body.opacity(0.14))
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("日期", point.date),
                    y: .value("体重", point.value)
                )
                .foregroundStyle(ChartColor.body)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis { dateAxis() }
            .chartYAxis { valueAxis() }
        }
    }

    private var displayedExercise: String {
        trackedExercises.contains(selectedExercise) ? selectedExercise : (trackedExercises.first ?? "")
    }

    private var oneRMChart: some View {
        let points = oneRMPoints.filter { $0.exercise == displayedExercise }
        return VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            chartTitle("动作实力（估算 1RM）", unit: "kg")
            Picker("动作", selection: Binding(
                get: { displayedExercise },
                set: { selectedExercise = $0 }
            )) {
                ForEach(trackedExercises, id: \.self) { name in Text(name).tag(name) }
            }
            .pickerStyle(.menu)
            if let latest = points.last {
                Text("\(Format.number(latest.value, decimals: 1)) kg")
                    .font(Theme.Font.metric)
                Text("最近一次 · \(Format.shortDay(latest.date))")
                    .font(Theme.Font.footnote)
                    .foregroundStyle(Theme.secondaryLabel)
            }
            Chart(points) { point in
                LineMark(x: .value("日期", point.date), y: .value("估算 1RM", point.value))
                    .foregroundStyle(ChartColor.training)
                    .lineStyle(StrokeStyle(lineWidth: 3))
                PointMark(x: .value("日期", point.date), y: .value("估算 1RM", point.value))
                    .foregroundStyle(ChartColor.training)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis { dateAxis() }
            .chartYAxis { valueAxis() }
            .frame(height: 170)
            Text("估算值不等于实际最大重量；单次记录只显示数据点。")
                .font(Theme.Font.footnote)
                .foregroundStyle(Theme.secondaryLabel)
        }
        .card()
    }

    private var volumeChart: some View {
        chartCard(title: "每周训练容量", unit: "kg") {
            Chart(volumePerWeek) { point in
                BarMark(
                    x: .value("周", point.week, unit: .weekOfYear),
                    y: .value("容量", point.volume)
                )
                // 只有本周用实色，其余中性灰 ——「哪根是本周」靠颜色而不是靠标注
                .foregroundStyle(
                    point.week == volumePerWeek.last?.week ? ChartColor.training : Theme.chip
                )
                .cornerRadius(3)
            }
            .chartXAxis { dateAxis() }
            .chartYAxis { valueAxis() }
        }
    }

    private var sleepChart: some View {
        chartCard(title: "睡眠", unit: "小时") {
            Chart(sleepPoints) { point in
                BarMark(
                    x: .value("日期", point.day, unit: .day),
                    y: .value("小时", point.hours)
                )
                .foregroundStyle(ChartColor.recovery)
                .cornerRadius(2)

                if let average = sleepAverage {
                    RuleMark(y: .value("平均", average))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 5]))
                        .foregroundStyle(ChartColor.baseline)
                }
            }
            .chartYScale(domain: 0...max(10, (sleepPoints.map(\.hours).max() ?? 8) + 1))
            .chartXAxis { dateAxis() }
            .chartYAxis { valueAxis() }
        }
    }

    private func chartCard<Content: View>(
        title: String,
        unit: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            chartTitle(title, unit: unit)
            content()
                .frame(height: 170)
        }
        .card()
    }

    /// 图表标题写在卡片里（和洞察页的 hero 卡一致）——
    /// 这和「列表分组标题放卡片外」不冲突：那是分区，这是图表自己的标题。
    private func chartTitle(_ title: String, unit: String) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(title)
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(Theme.secondaryLabel)
            Spacer(minLength: 0)
            Text(unit)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.tertiaryLabel)
        }
    }

    /// 横轴只出标签，**不画竖网格线**
    private func dateAxis() -> some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
            AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                .font(Theme.Font.badge)
                .foregroundStyle(Theme.tertiaryLabel)
        }
    }

    /// 纵轴画水平网格线
    private func valueAxis() -> some AxisContent {
        AxisMarks(position: .leading) { _ in
            AxisGridLine().foregroundStyle(Theme.hairline)
            AxisValueLabel()
                .font(Theme.Font.badge)
                .foregroundStyle(Theme.tertiaryLabel)
        }
    }
}

#Preview {
    TrendsView()
        .modelContainer(try! AppModelContainer.inMemory())
}
