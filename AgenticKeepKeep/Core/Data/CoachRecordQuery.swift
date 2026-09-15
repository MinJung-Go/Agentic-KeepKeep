import Foundation
import SwiftData

struct CoachRecordQuery: Decodable {
    enum Kind: String, Decodable { case health, training, nutrition, body, plan }
    let kind: Kind
    let start_date: String
    let end_date: String
    var exercise: String?
    var plan_id: String? = nil

    func interval(now: Date, timeZone: TimeZone = .current) throws -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func date(_ value: String) -> Date? {
            let bytes = Array(value.utf8)
            guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
                  bytes.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) }) else { return nil }
            let fields = value.split(separator: "-").compactMap { Int($0) }
            guard fields.count == 3 else { return nil }
            let components = DateComponents(timeZone: timeZone, year: fields[0], month: fields[1], day: fields[2])
            guard components.isValidDate(in: calendar), let result = calendar.date(from: components) else { return nil }
            let actual = calendar.dateComponents([.year, .month, .day], from: result)
            guard actual.year == fields[0], actual.month == fields[1], actual.day == fields[2] else { return nil }
            return result
        }
        guard let start = date(start_date), let last = date(end_date),
              start <= last, (kind == .plan || last <= calendar.startOfDay(for: now)),
              let days = calendar.dateComponents([.day], from: start, to: last).day, days < 31,
              let end = calendar.date(byAdding: .day, value: 1, to: last),
              (exercise?.utf8.count ?? 0) <= 120 else {
            throw QueryError.invalidRange
        }
        return DateInterval(start: start, end: end)
    }

    enum QueryError: LocalizedError {
        case invalidRange, tooManyRecords
        var errorDescription: String? {
            switch self {
            case .invalidRange: return "日期必须为有效的本地 yyyy-MM-dd，范围不超过31天；健康和每日记录不能晚于今天。"
            case .tooManyRecords: return "该区间记录过多，请缩小日期范围；未返回不完整统计。"
            }
        }
    }
}

/// Bounded database reads, explicit aggregation, no raw notes/photos or source identifiers.
@MainActor
enum CoachRecordStore {
    static func query(_ query: CoachRecordQuery, context: ModelContext, now: Date = .now) throws -> CoachToolResult {
        let interval = try query.interval(now: now)
        let start = interval.start, end = interval.end
        let cutoff = min(end, now.addingTimeInterval(0.001))
        var lines = ["本地日期 \(query.start_date) 至 \(query.end_date)（含首尾），时区 \(TimeZone.current.identifier)。",
                     "仅统计已保存/已同步的数据；缺失不按零补齐，记录为空不代表没有活动。"]
        switch query.kind {
        case .plan:
            let plans = try fetch(FetchDescriptor<Plan>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]), context)
            guard let rawID = query.plan_id else {
                lines.append("课程表索引（索引不按日期过滤，最多10份）：")
                for plan in plans.prefix(10) {
                    lines.append("planID=\(plan.uuid.uuidString) 《\(String(plan.title.prefix(40)))》\(plan.isActive ? "进行中" : "已归档")")
                }
                if plans.count > 10 { lines.append("仅展示最近10份，可提供具体plan_id查询更早课程表。") }
                return CoachToolResult(content: lines.joined(separator: "\n"))
            }
            guard let id = UUID(uuidString: rawID), let plan = plans.first(where: { $0.uuid == id }) else {
                return CoachToolResult(content: "目标课程表不存在，请重新查询索引。")
            }
            lines.append("planID=\(plan.uuid.uuidString) revision=\(PlanMutationStore.revision(plan)) 《\(String(plan.title.prefix(60)))》")
            let days = plan.sortedDays.filter { $0.date >= start && $0.date < end }
            for day in days.prefix(10) {
                lines.append("dayID=\(day.uuid.uuidString) \(localDay(day.date)) \(String(day.title.prefix(40))) [\(day.statusRaw)]")
                for exercise in day.sortedExercises.prefix(12) {
                    lines.append("\(String(exercise.name.prefix(40))) \(String(exercise.setsText.prefix(30))) 目标kg=\(exercise.targetWeightKg.map(number) ?? "未设定")")
                }
                if day.exercises.count > 12 { lines.append("动作未完整展示，请勿据此整日替换。") }
            }
            if days.count > 10 { lines.append("训练日仅展示前10项，请缩小日期范围。") }
            if days.isEmpty { lines.append("该日期范围没有训练日，课程表仍存在。") }
        case .health:
            let snapshots = try fetch(FetchDescriptor<HealthSnapshot>(predicate: #Predicate { $0.day >= start && $0.day < end }), context)
            let workouts = try fetch(FetchDescriptor<HealthWorkout>(predicate: #Predicate { $0.date >= start && $0.date < cutoff }), context)
            lines.append("Apple 健康快照覆盖 \(Set(snapshots.map(\.day)).count) 天。")
            lines += [stat("步数", snapshots.map { Double($0.steps) }, unit: "步"),
                      stat("活动能量", snapshots.map(\.activeEnergyKcal), unit: "kcal"),
                      stat("睡眠", snapshots.map(\.sleepHours), unit: "小时"),
                      stat("HRV", snapshots.map(\.hrvMs), unit: "ms"),
                      stat("静息心率", snapshots.map(\.restingHeartRate), unit: "bpm")]
            lines.append("Apple 健康运动 \(workouts.count) 次，合计 \(number(workouts.map(\.durationMinutes).filter(valid).reduce(0,+))) 分钟；与 Moveliq 手动训练分开，勿相加去重。")
            if let updated = snapshots.map(\.updatedAt).max() {
                lines.append("区间内最新快照同步时间：\(ISO8601DateFormatter().string(from: updated))；不是实时读数。")
            }
        case .training:
            let sessions = try fetch(FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.date >= start && $0.date < cutoff }, sortBy: [SortDescriptor(\.date)]), context)
            let matching = sessions.filter { session in query.exercise == nil || session.sets.contains { $0.exerciseName == query.exercise } }
            let sets = matching.flatMap(\.sets).filter { query.exercise == nil || $0.exerciseName == query.exercise }
            guard sets.count <= 10_000 else { throw CoachRecordQuery.QueryError.tooManyRecords }
            lines.append("Moveliq 内训练 \(matching.count) 次，容量 \(number(sets.map(\.volumeKg).filter(valid).reduce(0,+))) kg；不含 Apple 健康运动。")
            let groups = Dictionary(grouping: sets, by: \.exerciseName)
            for name in groups.keys.sorted().prefix(5) {
                let values = (groups[name] ?? []).map(\.estimatedOneRepMax).filter(valid)
                lines.append("动作 \(String(name.prefix(32)))：估算1RM 最佳 \(number(values.max() ?? 0))、最近 \(number(values.last ?? 0)) kg（无有效负重时为缺失，非实际测量）")
            }
            if groups.count > 5 { lines.append("动作仅展示前5项，可用 exercise 精确查询。") }
        case .nutrition:
            let meals = try fetch(FetchDescriptor<MealEntry>(predicate: #Predicate { $0.date >= start && $0.date < cutoff }), context)
            let days = Set(meals.map { Calendar.current.startOfDay(for: $0.date) }).count
            lines.append("饮食覆盖 \(days) 天，记录 \(meals.count) 餐；仅已记录摄入，不能推断全天饮食完整性。")
            if days > 0 {
                let divisor = Double(days)
                lines.append("有记录日的日均：能量 \(number(meals.map(\.totalCalories).filter(valid).reduce(0,+)/divisor)) kcal；蛋白质 \(number(meals.map(\.totalProteinG).filter(valid).reduce(0,+)/divisor)) g；碳水 \(number(meals.map(\.totalCarbsG).filter(valid).reduce(0,+)/divisor)) g；脂肪 \(number(meals.map(\.totalFatG).filter(valid).reduce(0,+)/divisor)) g。")
            }
        case .body:
            let values = try fetch(FetchDescriptor<BodyMetric>(predicate: #Predicate { $0.date >= start && $0.date < cutoff }, sortBy: [SortDescriptor(\.date)]), context)
            for kind in MetricKind.allCases {
                let samples = values.filter { $0.kindRaw == kind.rawValue && valid($0.value) }
                if let first = samples.first, let last = samples.last {
                    lines.append("\(kind.displayName)：\(samples.count) 条，首值 \(number(first.value))、末值 \(number(last.value)) \(kind.unit)；末值记录日期 \(localDay(last.date))。")
                } else { lines.append("\(kind.displayName)：没有可用记录。") }
            }
        }
        return CoachToolResult(content: lines.joined(separator: "\n"))
    }

    private static func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>, _ context: ModelContext) throws -> [T] {
        var bounded = descriptor
        bounded.fetchLimit = 2001
        let values = try context.fetch(bounded)
        guard values.count <= 2000 else { throw CoachRecordQuery.QueryError.tooManyRecords }
        return values
    }

    private static func localDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func valid(_ value: Double) -> Bool { value.isFinite && value > 0 }
    private static func number(_ value: Double) -> String {
        value.isFinite ? String(format: "%.1f", value) : "缺失"
    }
    private static func stat(_ label: String, _ input: [Double], unit: String) -> String {
        let values = input.filter(valid)
        guard !values.isEmpty else { return "\(label)：没有可用值。" }
        if values.count == 1 { return "\(label)：\(number(values[0])) \(unit)（区间内仅1天有值，不代表其他日期）。" }
        return "\(label)：日均 \(number(values.reduce(0,+)/Double(values.count))) \(unit)，\(values.count) 天有值。"
    }
}
