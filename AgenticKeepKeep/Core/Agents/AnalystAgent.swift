import Foundation

/// 基于本地聚合摘要生成周/月报。
/// 隐私约束：只有 `AnalysisDigest`（聚合摘要）会被发出去，原始记录不出设备。
struct AnalystAgent {

    let client: LLMClient

    init(client: LLMClient) {
        self.client = client
    }

    func generateReport(from digest: AnalysisDigest) async throws -> AnalysisReportDraft {
        guard digest.hasData else { throw ReportGenerationError.noData }
        let request = LLMRequest(
            messages: [
                .system(AgentPrompts.analystSystem()),
                .user(digest.summaryText())
            ],
            temperature: 0.3,
            jsonMode: true
        )

        let response = try await client.complete(request)

        guard let content = response.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.emptyResponse
        }

        return try JSONExtractor.decode(AnalysisReportDraft.self, from: content)
    }
}


enum ReportGenerationError: LocalizedError {
    case noData
    var errorDescription: String? { "当前区间没有可分析的数据，请先同步健康数据或添加记录。" }
}
