import Foundation
import SwiftData

/// 动作编辑使用值类型草稿，浏览或取消不会修改持久化模型。
struct PlanExerciseEditDraft {
    var name: String
    var setsText: String
    var weightText: String

    init(_ exercise: PlanExercise) {
        name = exercise.name
        setsText = exercise.setsText
        weightText = exercise.targetWeightKg.map { String($0) } ?? ""
    }
}

@MainActor
enum PlanExerciseStore {
    enum EditError: LocalizedError {
        case invalidName, invalidWeight, missing
        var errorDescription: String? {
            switch self {
            case .invalidName: return "请填写动作名称。"
            case .invalidWeight: return "重量需为 0–2000 kg 的数字，留空表示未设置。"
            case .missing: return "这个动作已不存在，请返回课程表刷新。"
            }
        }
    }

    private static func find(_ id: UUID, context: ModelContext) throws -> PlanExercise {
        let request = FetchDescriptor<PlanExercise>(predicate: #Predicate { $0.uuid == id })
        guard let exercise = try context.fetch(request).first else { throw EditError.missing }
        return exercise
    }

    static func save(_ draft: PlanExerciseEditDraft, id: UUID, context: ModelContext) throws {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw EditError.invalidName }
        let text = draft.weightText.trimmingCharacters(in: .whitespacesAndNewlines)
        var weight: Double?
        if !text.isEmpty {
            let formatter = NumberFormatter()
            formatter.locale = .current
            let separator = formatter.decimalSeparator ?? "."
            let normalized = text.replacingOccurrences(of: separator, with: ".")
            guard let value = Double(normalized), value.isFinite, (0...2000).contains(value) else {
                throw EditError.invalidWeight
            }
            weight = value
        }
        let exercise = try find(id, context: context)
        try context.save()
        do {
            exercise.name = name
            exercise.setsText = draft.setsText.trimmingCharacters(in: .whitespacesAndNewlines)
            exercise.targetWeightKg = weight
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    static func delete(id: UUID, day: PlanDay, context: ModelContext) throws {
        let exercise = try find(id, context: context)
        guard exercise.day?.uuid == day.uuid else { throw EditError.missing }
        try context.save()
        do {
            day.exercises.removeAll { $0.uuid == id }
            context.delete(exercise)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
