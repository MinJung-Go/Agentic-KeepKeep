import Foundation

/// 食物照片 → 热量估算（P2）。
/// 需要支持图片输入的模型；不支持的模型会返回错误，由调用方降级为手填。
struct VisionAgent {

    let client: LLMClient

    init(client: LLMClient) {
        self.client = client
    }

    /// - Parameter imageBase64JPEG: base64 编码的 JPEG（不含 data: 前缀）
    func analyzeMeal(imageBase64JPEG: String, note: String? = nil, now: Date = .now) async throws -> ParsedMeal {
        var prompt = "请估算这张照片里食物的组成与营养。"
        if let note, !note.trimmingCharacters(in: .whitespaces).isEmpty {
            prompt += "用户补充说明：\(note)"
        }
        prompt += "\n当前时间：\(Self.dateText(now))"

        let request = LLMRequest(
            messages: [
                .system(AgentPrompts.visionSystem()),
                .userWithImage(prompt, imageBase64JPEG: imageBase64JPEG)
            ],
            temperature: 0.2,
            jsonMode: true
        )

        let response = try await client.complete(request)

        guard let content = response.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.emptyResponse
        }

        return try JSONExtractor.decode(ParsedMeal.self, from: content)
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
