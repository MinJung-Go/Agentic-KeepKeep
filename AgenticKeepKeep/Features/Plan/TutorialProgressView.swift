import SwiftUI
import SwiftData

struct TutorialProgressView: View {
    let names: [String]
    @Environment(\.modelContext) private var context
    @ObservedObject private var store = ExerciseTutorialStore.shared
    @ObservedObject private var settings = LLMSettings.shared
    @Query private var cache: [ExerciseTutorialCache]
    @State private var batch: Task<Void, Never>?
    private var keys: Set<String> { Set(names.compactMap { TutorialExercise.resolve($0)?.name }) }
    private var relevant: [ExerciseTutorialCache] { cache.filter { keys.contains($0.key) } }
    private var running: Bool { !store.running.intersection(keys).isEmpty }
    private var ready: Int { relevant.filter { !ExerciseTutorialStore.entries($0).isEmpty }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if running {
                HStack { ProgressView().controlSize(.small); Text("正在补充动作教学 · \(ready) / \(keys.count)") }
                Button("停止补充") { batch?.cancel(); store.stopAll() }
            } else {
                Text(settings.webSearchEnabled ? "教学已找到 \(ready) / \(Set(names).count) · 在动作详情查看" : "联网搜索已关闭 · 课程照常可用")
                if settings.webSearchEnabled && settings.supportsWebSearch && ready < keys.count {
                    Button("继续补充教学") {
                        batch?.cancel()
                        batch = Task { await store.enrich(names: names, context: context, retryUnresolved: true) }
                    }
                }
            }
            DisclosureGroup("查看教学补充过程") {
                ForEach(keys.sorted(), id: \.self) { key in
                    let events = store.activities[key] ?? CoachToolActivity.decode(relevant.first { $0.key == key }?.activityJSON)
                    if !events.isEmpty {
                        Text(key).font(.footnote.weight(.medium))
                        CoachToolActivityView(activities: events)
                    }
                }
            }
            Text("课程已就绪，教学链接不会影响开始训练。")
                .foregroundStyle(.secondary)
        }.font(.footnote).foregroundStyle(Theme.secondaryLabel)
    }
}
