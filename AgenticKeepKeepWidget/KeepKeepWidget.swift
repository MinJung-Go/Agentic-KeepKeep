import SwiftData
import SwiftUI
import WidgetKit

/// 桌面小组件：今天练什么 + 今天记了多少
@main
struct KeepKeepWidgetBundle: WidgetBundle {
    var body: some Widget {
        KeepKeepWidget()
    }
}

struct KeepKeepEntry: TimelineEntry {
    let date: Date
    let planTitle: String?
    let planDetail: String?
    /// 当前计划的完成度（0...1），没有计划时为 nil
    let planProgress: Double?
    let planWeekText: String?
    let todayCount: Int
    let hasData: Bool

    static let empty = KeepKeepEntry(
        date: .now,
        planTitle: nil,
        planDetail: nil,
        planProgress: nil,
        planWeekText: nil,
        todayCount: 0,
        hasData: false
    )
}

struct KeepKeepProvider: TimelineProvider {

    func placeholder(in context: Context) -> KeepKeepEntry {
        KeepKeepEntry(
            date: .now,
            planTitle: "胸 + 三头",
            planDetail: "哑铃卧推 4×10 等 5 个动作",
            planProgress: 0.5,
            planWeekText: "第 2 / 4 周",
            todayCount: 2,
            hasData: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (KeepKeepEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<KeepKeepEntry>) -> Void) {
        let entry = currentEntry()
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now.addingTimeInterval(1_800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    /// 从 App Group 的 SwiftData 读取今天的课程与记录数
    private func currentEntry() -> KeepKeepEntry {
        guard let container = AppModelContainer.widgetContainer() else {
            return .empty
        }
        let context = ModelContext(container)

        let start = Calendar.current.startOfDay(for: .now)
        let end = start.addingTimeInterval(86_400)

        var planTitle: String?
        var planDetail: String?
        var planProgress: Double?
        var planWeekText: String?

        let planDescriptor = FetchDescriptor<PlanDay>(
            predicate: #Predicate { $0.date >= start && $0.date < end }
        )
        if let day = try? context.fetch(planDescriptor).first {
            planTitle = day.title
            planDetail = day.exerciseSummary

            if let plan = day.plan, !plan.days.isEmpty {
                planProgress = Double(plan.completedCount) / Double(plan.days.count)
                planWeekText = "第 \(Format.currentWeek(since: plan.startDate, total: plan.weeks)) / \(plan.weeks) 周"
            }
        }

        var count = 0
        count += (try? context.fetchCount(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.date >= start && $0.date < end }
        ))) ?? 0
        count += (try? context.fetchCount(FetchDescriptor<MealEntry>(
            predicate: #Predicate { $0.date >= start && $0.date < end }
        ))) ?? 0
        count += (try? context.fetchCount(FetchDescriptor<BodyMetric>(
            predicate: #Predicate { $0.date >= start && $0.date < end }
        ))) ?? 0

        return KeepKeepEntry(
            date: .now,
            planTitle: planTitle,
            planDetail: planDetail,
            planProgress: planProgress,
            planWeekText: planWeekText,
            todayCount: count,
            hasData: planTitle != nil || count > 0
        )
    }
}

struct KeepKeepWidget: Widget {

    let kind = "KeepKeepWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: KeepKeepProvider()) { entry in
            KeepKeepWidgetView(entry: entry)
        }
        .configurationDisplayName("Moveliq · 今日训练")
        .description("今天练什么、记了多少，一眼看到。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

/// 小组件只出现**单色 + 透明度**的层次，不引入语义色。
///
/// 这样在全彩 / 色调化（tinted）两种渲染模式下都成立 —— tinted 模式下系统会把内容
/// 重刷成单色，本来靠颜色区分的层次会全部塌掉，只剩字重与透明度还靠得住（FR14.5）。
struct KeepKeepWidgetView: View {

    @Environment(\.widgetFamily) private var family

    let entry: KeepKeepEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 4) {
                    Label(entry.planTitle ?? "今天还没安排训练", systemImage: "dumbbell")
                        .font(.headline)
                        .lineLimit(1)
                    Text(entry.planWeekText ?? "今天已记 \(entry.todayCount) 条")
                        .font(.caption)
                        .lineLimit(1)
                }
            case .systemSmall: smallBody
            default: mediumBody
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: - 小号：今天这一课

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            Spacer(minLength: 0)

            if let title = entry.planTitle {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(2)

                if let progress = entry.planProgress {
                    ProgressView(value: progress)
                        .tint(.primary)
                        .padding(.top, 2)
                }

                if let week = entry.planWeekText {
                    Text(week)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            } else if entry.todayCount > 0 {
                Text("今天已记 \(entry.todayCount) 条")
                    .font(.system(size: 17, weight: .bold))
            } else {
                Text("今天还没记录")
                    .font(.system(size: 16, weight: .semibold))
                Text("说一句「深蹲100kg 5×5」")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - 中号：今天练什么 + 记了多少

    private var mediumBody: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                header

                Spacer(minLength: 0)

                if let title = entry.planTitle {
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(1)
                    if let detail = entry.planDetail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let week = entry.planWeekText {
                        Text(week)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("今天没有安排训练")
                        .font(.system(size: 17, weight: .semibold))
                    Text("打开 App 制定计划")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if let progress = entry.planProgress {
                VStack(spacing: 6) {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 22, weight: .bold))
                        .monospacedDigit()
                    Text("计划完成")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .widgetAccentable()
            } else {
                VStack(spacing: 2) {
                    Text("\(entry.todayCount)")
                        .font(.system(size: 26, weight: .bold))
                        .monospacedDigit()
                    Text("今日记录")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .widgetAccentable()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "dumbbell.fill")
                .font(.system(size: 11, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
            Text("今日")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

#Preview(as: .systemSmall) {
    KeepKeepWidget()
} timeline: {
    KeepKeepEntry(
        date: .now, planTitle: "胸 + 三头", planDetail: "哑铃卧推 4×10 等 5 个动作",
        planProgress: 0.5, planWeekText: "第 2 / 4 周", todayCount: 2, hasData: true
    )
    KeepKeepEntry.empty
}

#Preview(as: .systemMedium) {
    KeepKeepWidget()
} timeline: {
    KeepKeepEntry(
        date: .now, planTitle: "胸 + 三头", planDetail: "哑铃卧推 4×10 等 5 个动作",
        planProgress: 0.5, planWeekText: "第 2 / 4 周", todayCount: 2, hasData: true
    )
    KeepKeepEntry.empty
}
