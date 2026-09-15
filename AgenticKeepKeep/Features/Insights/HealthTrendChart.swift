import Charts
import SwiftUI

struct HealthTrendChart: View {
    let series: HealthTrendSeries

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack {
                Text(series.title).font(Theme.Font.subheadline.weight(.semibold))
                Spacer()
                Text(series.unit).font(Theme.Font.caption).foregroundStyle(Theme.secondaryLabel)
            }
            if let latest = series.points.last {
                Text("\(Format.number(latest.value, decimals: series.metric == .minutes ? 1 : 0)) \(series.unit)")
                    .font(Theme.Font.metric)
                Text("最近记录 · \(Format.shortDay(latest.day))")
                    .font(Theme.Font.footnote).foregroundStyle(Theme.secondaryLabel)
            }
            Chart(series.points) { point in
                BarMark(x: .value("日期", point.day, unit: .day), y: .value(series.title, point.value))
                    .foregroundStyle(ChartColor.recovery)
                    .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                }
            }
            .frame(height: 150)
            Text(series.metric == .energy
                 ? "Apple 健康 · 活动能量不含静息消耗，不能当作全天总消耗。"
                 : "Apple 健康 · 仅显示已有数据，未同步的日期不补零。")
                .font(Theme.Font.footnote).foregroundStyle(Theme.secondaryLabel)
        }
        .card()
    }
}
