import Foundation
import SwiftData

/// SwiftData 容器工厂。SwiftData 是全 App 唯一数据源。
enum AppModelContainer {

    /// App Group：让桌面小组件能读到同一份数据。
    /// 需要最终签名包含 App Group 能力；没有该能力时会退回本地容器（App 照常可用，小组件显示空态）。
    static let appGroupID = "group.com.minjung.keepkeep"

    /// 先用 FileManager 探测 App Group 容器是否真的可用。
    /// 必须探测：没有该 entitlement 时，SwiftData 的 groupContainer 会直接 fatalError（不可捕获），
    /// 而 containerURL 在同样条件下只是返回 nil。
    static var appGroupAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
    }

    /// 全部模型类型（新增模型时在此登记）
    static var schema: Schema {
        Schema([
            WorkoutSession.self,
            ExerciseTutorialCache.self,
            ExerciseSet.self,
            MealEntry.self,
            FoodItem.self,
            BodyMetric.self,
            HealthSnapshot.self,
            HealthWorkout.self,
            RawNote.self,
            AnalysisReport.self,
            Plan.self,
            PlanDay.self,
            PlanExercise.self,
            ChatMessage.self,
            SetLog.self,
            WorkoutSessionDraft.self
        ])
    }

    /// App 运行期共享容器。
    /// 顺序：App Group（小组件可读）→ 本地容器 → 内存模式（保证 App 仍能启动）。
    static let shared: ModelContainer = {
        if appGroupAvailable,
           let group = try? ModelContainer(
               for: schema,
               configurations: ModelConfiguration(groupContainer: .identifier(appGroupID))
           ) {
            return group
        }

        do {
            return try ModelContainer(for: schema)
        } catch {
            assertionFailure("本地数据库初始化失败，已退回内存模式：\(error)")
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            // 内存模式不应失败；失败则无法运行，直接终止并给出信息
            do {
                return try ModelContainer(for: schema, configurations: config)
            } catch {
                fatalError("无法创建 SwiftData 容器：\(error)")
            }
        }
    }()

    /// 小组件专用：只读共享容器，取不到就返回 nil（界面显示空态）
    static func widgetContainer() -> ModelContainer? {
        guard appGroupAvailable else { return nil }
        return try? ModelContainer(
            for: schema,
            configurations: ModelConfiguration(groupContainer: .identifier(appGroupID))
        )
    }

    /// 测试 / 预览用内存容器
    static func inMemory() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }
}
