import XCTest
@testable import AgenticKeepKeep

final class LocalMemoryPolicyTests: XCTestCase {
    func testUnknownTokensAreNotReportedAsZero() {
        let diagnostic = LocalInferenceDiagnostic()
        diagnostic.update(stage: .loading, vision: false, footprint: nil)
        XCTAssertTrue(diagnostic.summary.contains("尚未计数"))
        XCTAssertTrue(diagnostic.summary.contains("未取得"))
        XCTAssertTrue(diagnostic.summary.contains("模型加载"))
    }
    func testSamplingKeepsStageAndPeakWithoutConversationData() {
        let diagnostic = LocalInferenceDiagnostic()
        diagnostic.update(stage: .prefill, tokens: 420, vision: true, footprint: 100 * 1_048_576)
        diagnostic.sample(footprint: 150 * 1_048_576)
        diagnostic.sample(footprint: 120 * 1_048_576)
        XCTAssertEqual(diagnostic.summary, "阶段：首字计算；路径：图文；输入：420 tokens；进程采样峰值：150 MiB。")
        XCTAssertTrue(LocalMemoryDiagnosticError(summary: diagnostic.summary).localizedDescription.contains("L14"))
    }
}
