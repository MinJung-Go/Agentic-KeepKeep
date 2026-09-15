import Charts
import SwiftUI
import SwiftData

/// 饮食分析：日均摄入 + 宏营养素当前值/目标 + 每日热量
///
/// 用「当前值 / 目标」而不是只报数字 —— 蛋白质目标按体重 × 1.6g/kg 算，
/// 界面上要写出这个算法，用户才知道缺口是怎么来的（FR8）。
struct NutritionAnalysisView: View {

    @Query(sort: [SortDescriptor(\MealEntry.date)])
    private var meals: [MealEntry]
    @Query(sort: [SortDescriptor(\BodyMetric.date, order: .reverse)])
    private var metrics: [BodyMetric]

    @Query private var snapshots: [HealthSnapshot]
    @Query private var healthWorkouts: [HealthWorkout]

    private var activitySeries: [HealthTrendSeries] {
        HealthTrendSeries.build(snapshots: snapshots, workouts: healthWorkouts, days: days)
            .filter { $0.metric == .energy || $0.metric == .minutes || $0.metric == .steps }
    }

    @State private var days = 7

    private var rangeStart: Date {
        Calendar.current.startOfDay(for: .now).addingTimeInterval(-Double(days - 1) * 86_400)
    }

    private var mealsInRange: [MealEntry] {
        meals.filter { $0.date >= rangeStart }
    }

    private var analysis: NutritionAnalysis {
        // metrics 按日期倒序，第一条体重就是最近一次
        NutritionAnalysis.build(
            meals: mealsInRange,
            latestWeightKg: metrics.first { $0.kind == .weight }?.value,
            daysInRange: days
        )
    }

    private var dailyCalories: [(day: Date, calories: Double)] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: mealsInRange) { calendar.startOfDay(for: $0.date) }

        // 从区间第一天到最后一天逐日铺开，没有记录的那天也留一格（图上显示为矮柱）
        return (0..<days).reversed().compactMap { daysAgo -> (day: Date, calories: Double)? in
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: .now)),
                  day >= rangeStart else { return nil }
            return (day, grouped[day]?.reduce(0) { $0 + $1.totalCalories } ?? 0)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                Picker("区间", selection: $days) {
                    Text("近 7 天").tag(7)
                    Text("近 14 天").tag(14)
                    Text("近 30 天").tag(30)
                }
                .pickerStyle(.segmented)

                ForEach(activitySeries) { series in
                    HealthTrendChart(series: series)
                }

                if analysis.hasData {
                    intakeCard
                    macroCard
                    calorieChartCard

                    Text(analysis.insight)
                        .font(Theme.Font.footnote)
                        .foregroundStyle(Theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    EmptyStateView(
                        symbol: "fork.knife",
                        tint: Theme.positive,
                        title: "这段时间还没有饮食记录",
                        message: activitySeries.isEmpty
                            ? "用一句话记录，比如「中午吃了牛肉面」"
                            : "上方显示已同步的活动数据。还没有摄入记录，暂时无法分析营养素或热量缺口。"
                    )
                }
            }
            .padding(Theme.Spacing.l)
        }
        .background(Theme.canvas)
        .navigationTitle("饮食分析")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 日均摄入

    private var intakeCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                Text("近 \(days) 天日均")
                    .font(Theme.Font.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondaryLabel)
                Spacer(minLength: 0)
                Text("已记 \(analysis.daysLogged) / \(days) 天")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.secondaryLabel)
                    .monospacedDigit()
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(Format.number(analysis.avgCalories))
                    .font(.system(size: 34, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("kcal")
                    .font(Theme.Font.footnote)
                    .foregroundStyle(Theme.secondaryLabel)
            }

            Text("按有记录的 \(analysis.daysLogged) 天计算，未记录的日子不计入平均")
                .font(Theme.Font.badge)
                .fontWeight(.regular)
                .foregroundStyle(Theme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    // MARK: - 宏营养素

    /// 三行共用一套结构：名称（+ 缺口徽标）→ 进度条 → 当前 / 目标
    private var macroCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("宏营养素")
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(Theme.secondaryLabel)

            VStack(spacing: Theme.Spacing.m) {
                if let target = analysis.proteinTargetG, let gap = analysis.proteinGapG {
                    macroRow(
                        name: "蛋白质",
                        current: analysis.avgProteinG,
                        target: target,
                        tint: ChartColor.body,
                        badge: gap > 10 ? Badge("差 \(Format.number(gap))g", tone: .bright(Theme.warning)) : Badge("已达标", tone: .solid(Theme.positive)),
                        footnote: "目标按体重 \(Format.number(analysis.latestWeightKg ?? 0, decimals: 1))kg × 1.6g/kg 估算"
                    )
                } else {
                    macroRow(
                        name: "蛋白质",
                        current: analysis.avgProteinG,
                        target: nil,
                        tint: ChartColor.body,
                        badge: nil,
                        footnote: "记一次体重后才能算出蛋白质目标"
                    )
                }

                macroRow(name: "碳水", current: analysis.avgCarbsG, target: nil, tint: ChartColor.recovery, badge: nil, footnote: nil)
                macroRow(name: "脂肪", current: analysis.avgFatG, target: nil, tint: ChartColor.training, badge: nil, footnote: nil)
            }
        }
        .card()
    }

    private func macroRow(
        name: String,
        current: Double,
        target: Double?,
        tint: Color,
        badge: Badge?,
        footnote: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Spacing.s) {
                Text(name)
                    .font(Theme.Font.subheadline.weight(.semibold))
                if let badge { badge }
                Spacer(minLength: 0)
                Text("\(Format.number(current)) g")
                    .font(Theme.Font.subheadline.weight(.semibold))
                    .monospacedDigit()
            }

            if let target {
                ProgressBar(value: current / max(1, target), tint: tint)
            }

            Text(target.map { "目标 \(Format.number($0)) g" } ?? "暂无目标")
                .font(Theme.Font.badge)
                .fontWeight(.regular)
                .foregroundStyle(Theme.secondaryLabel)
                .monospacedDigit()

            if let footnote {
                Text(footnote)
                    .font(Theme.Font.badge)
                    .fontWeight(.regular)
                    .foregroundStyle(Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 每日热量

    private var calorieChartCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                Text("每日热量")
                    .font(Theme.Font.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondaryLabel)
                Spacer(minLength: 0)
                Text("灰色 = 未记录")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.secondaryLabel)
            }

            DailyCaloriesChart(points: dailyCalories)
                .frame(height: 150)
        }
        .card()
    }
}

/// 每日热量柱状图。**只有超过平均的那几天用实色**，其余中性灰 ——
/// 这样「哪几天吃够了」一眼就分得出来，不用去看刻度。
struct DailyCaloriesChart: View {

    let points: [(day: Date, calories: Double)]

    private var averageCalories: Double? {
        let logged = points.filter { $0.calories > 0 }.map(\.calories)
        guard !logged.isEmpty else { return nil }
        return logged.reduce(0, +) / Double(logged.count)
    }

    var body: some View {
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                BarMark(
                    x: .value("日期", point.day, unit: .day),
                    y: .value("热量", point.calories)
                )
                .foregroundStyle(isEmphasized(point.calories) ? ChartColor.training : Theme.chip)
                .cornerRadius(3)
            }

            if let average = averageCalories {
                RuleMark(y: .value("平均", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 5]))
                    .foregroundStyle(ChartColor.baseline)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("平均 \(Format.number(average))")
                            .font(Theme.Font.badge)
                            .fontWeight(.regular)
                            .foregroundStyle(Theme.secondaryLabel)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                    .font(Theme.Font.badge)
                    .foregroundStyle(Theme.secondaryLabel)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel()
                    .font(Theme.Font.badge)
                    .foregroundStyle(Theme.secondaryLabel)
            }
        }
    }

    private func isEmphasized(_ calories: Double) -> Bool {
        guard let average = averageCalories, calories > 0 else { return false }
        return calories >= average
    }
}

#Preview {
    NavigationStack {
        NutritionAnalysisView()
            .modelContainer(try! AppModelContainer.inMemory())
    }
}
