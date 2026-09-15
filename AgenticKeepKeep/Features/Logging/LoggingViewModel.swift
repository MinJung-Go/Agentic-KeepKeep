import Foundation
import SwiftData

/// 记录闭环：对话式记录流的宿主。
/// 用户每说一句 → 追加一条消息 → 解析结果以可编辑卡片内联出现 → 确认后入库。
/// 任何一步失败都降级为 RawNote，绝不丢用户数据。
@MainActor
final class LoggingViewModel: ObservableObject {

    /// 对话流里的一条消息
    struct LogTurn: Identifiable {

        enum Kind {
            case user       // 用户输入
            case assistant  // 解析结果（可编辑卡片）
            case failure    // 失败与降级说明
        }

        let id = UUID()
        var kind: Kind
        var text: String = ""
        var drafts: [LogDraft] = []
        /// 已保存条数（nil 表示尚未保存）
        var savedCount: Int?
        /// 用户这条消息附带的照片 —— 气泡里要显示缩略图，所以留着原始数据
        var photoData: Data?

        var isSaved: Bool { savedCount != nil }
        var hasPhoto: Bool { photoData != nil }
    }

    @Published var turns: [LogTurn] = []
    @Published var inputText: String = ""
    @Published var isParsing = false

    private let settings: LLMSettings

    init(settings: LLMSettings = .shared) {
        self.settings = settings
    }

    var isConfigured: Bool { settings.isConfigured }

    var canSubmit: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isParsing
    }

    var hasTurns: Bool { !turns.isEmpty }

    /// 首页点发送后立即开始处理。先消费请求，弹窗重现时不会重复发送。
    func submitHomeInput(from state: AppState, context: ModelContext) async {
        let text = state.pendingLogText
        let photo = state.pendingLogPhoto
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photo != nil else { return }
        state.pendingLogText = ""
        state.pendingLogPhoto = nil
        inputText = text
        await submit(context: context, photo: photo)
    }

    // MARK: - 提交

    /// 发送一轮：只发文字、只发照片，或文字 + 照片（文字作为照片的补充说明）
    func submit(context: ModelContext, photo: Data? = nil) async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || photo != nil else { return }

        turns.append(LogTurn(kind: .user, text: text, photoData: photo))
        inputText = ""

        guard settings.isConfigured else {
            if !text.isEmpty {
                RecordImporter.storeRawNote(text, failureReason: "未配置 API Key", to: context)
            }
            turns.append(LogTurn(
                kind: .failure,
                text: "尚未配置 AI，这次没能解析。填好 API Key 后可以重新处理，也可以先手动记录。"
            ))
            return
        }

        isParsing = true
        defer { isParsing = false }

        do {
            let client = try settings.makeRecordingClient()
            let drafts: [LogDraft]

            if let photo {
                guard let base64 = ImageDownscaler.jpegBase64(from: photo) else {
                    turns.append(LogTurn(kind: .failure, text: "这张图片无法读取，请换一张再试，或改用文字记录。"))
                    return
                }
                drafts = try await visionDrafts(photo: photo, base64: base64, note: text, client: client)
            } else {
                // 不含本轮：本轮输入单独作为最后一条 user 消息
                let history = Self.historyTurns(from: Array(turns.dropLast()))
                let records = try await ParserAgent(client: client).parse(text, history: history)
                drafts = records.compactMap { LogDraft.from($0) }
            }

            guard !drafts.isEmpty else { throw AgentError.emptyResult }
            turns.append(LogTurn(kind: .assistant, drafts: drafts))
        } catch {
            appendFailure(for: error, text: text, hasPhoto: photo != nil, context: context)
        }
    }

    /// 照片识别：把用户附带的文字作为补充说明一起发过去
    private func visionDrafts(photo: Data, base64: String, note: String, client: LLMClient) async throws -> [LogDraft] {
        let meal = try await VisionAgent(client: client).analyzeMeal(
            imageBase64JPEG: base64,
            note: note.isEmpty ? nil : note
        )

        var draft = LogDraft(kind: .meal)
        draft.meal = MealDraft(from: meal)
        draft.meal.photoData = ImageDownscaler.jpegData(from: photo)
        return [draft]
    }

    /// 失败处理：文字留存为 RawNote，照片无法留存但要给出可执行的提示
    private func appendFailure(for error: Error, text: String, hasPhoto: Bool, context: ModelContext) {
        if hasPhoto {
            let message = (error as? LLMError).map(Self.photoFailureMessage(for:))
                ?? "照片识别失败：\(error.localizedDescription)"
            turns.append(LogTurn(kind: .failure, text: message))
            return
        }

        if !text.isEmpty {
            RecordImporter.storeRawNote(text, failureReason: error.localizedDescription, to: context)
        }
        turns.append(LogTurn(
            kind: .failure,
            text: "没能解析这句：\(error.localizedDescription)\n原文已保存为「待归类」笔记，不会丢；也可以改用下面的手动记录。"
        ))
    }

    /// 把照片识别的常见失败翻译成可执行的提示
    static func photoFailureMessage(for error: LLMError) -> String {
        switch error {
        case .http(let status, let body):
            switch status {
            case 400, 404, 415, 422:
                return "当前模型似乎不支持图片输入（HTTP \(status)）。请在「设置 → 模型」换用支持视觉的模型，或改用文字记录。\n服务返回：\(body)"
            case 401, 403:
                return "API Key 无效或没有该模型权限（HTTP \(status)）。请在设置里检查。"
            case 429:
                return "请求过于频繁或额度不足（HTTP 429），稍后再试。"
            default:
                return "服务返回错误（HTTP \(status)）：\(body)"
            }
        case .network(let message):
            return "网络不可用，照片没有上传。稍后重试，或改用文字记录。\n\(message)"
        default:
            return "照片识别失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 手动记录

    func addManualDraft(_ kind: LogDraft.Kind) {
        turns.append(LogTurn(kind: .assistant, drafts: [LogDraft(kind: kind)]))
    }

    // MARK: - 保存

    /// 保存某一轮的全部草稿
    @discardableResult
    func save(turnID: UUID, context: ModelContext) -> Int {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return 0 }

        var turn = turns[index]
        guard !turn.isSaved else { return 0 }
        var total = 0

        for draft in turn.drafts where !draft.isEmpty {
            do {
                let summary = try RecordImporter.apply([draft.toParsedRecord()], to: context)

                if draft.kind == .meal, let photo = draft.meal.photoData, summary.meals > 0 {
                    RecordImporter.attachPhoto(photo, toNewestMealIn: context)
                }

                total += summary.total
            } catch {
                continue
            }
        }

        if total > 0 {
            turn.savedCount = total
            turns[index] = turn
        }

        return total
    }

    func removeTurn(_ id: UUID) {
        turns.removeAll { $0.id == id }
    }

    func reset() {
        turns = []
        inputText = ""
        isParsing = false
    }

    // MARK: - 对话历史（供多轮解析）

    /// 把对话流压缩成 LLM 上下文：用户原话 + 已确认记录的摘要
    static func historyTurns(from turns: [LogTurn]) -> [CoachTurn] {
        turns.compactMap { turn in
            switch turn.kind {
            case .user:
                return CoachTurn(role: .user, content: turn.text)

            case .assistant:
                let summary = turn.drafts.map(summaryLine(for:)).filter { !$0.isEmpty }.joined(separator: "；")
                guard !summary.isEmpty else { return nil }
                return CoachTurn(role: .assistant, content: "上一轮已解析：" + summary)

            case .failure:
                return nil
            }
        }
    }

    /// 单条草稿的紧凑摘要（用于上下文）
    static func summaryLine(for draft: LogDraft) -> String {
        switch draft.kind {
        case .workout:
            let exercises = draft.workout.exercises.compactMap { exercise -> String? in
                let name = exercise.name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }

                var text = name
                if let weight = ParsedInput.double(exercise.weightText) {
                    text += " \(Format.number(weight, decimals: weight == weight.rounded() ? 0 : 1))kg"
                }
                if let reps = ParsedInput.int(exercise.repsText) { text += " ×\(reps)次" }
                if let sets = ParsedInput.int(exercise.setsText) { text += " \(sets)组" }
                return text
            }
            return exercises.isEmpty ? "" : "训练 " + exercises.joined(separator: "、")

        case .meal:
            let names = draft.meal.items.map(\.name).filter { !$0.isEmpty }
            return names.isEmpty ? "" : "饮食 " + names.joined(separator: "、")

        case .metric:
            return "\(draft.metric.kind.displayName) \(draft.metric.valueText)\(draft.metric.kind.unit)"

        case .note:
            return draft.note.text.isEmpty ? "" : "笔记：" + draft.note.text
        }
    }
}
