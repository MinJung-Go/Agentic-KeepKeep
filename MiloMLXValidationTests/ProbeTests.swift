import XCTest
@testable import MiloMLXValidation

final class ProbeTests: XCTestCase {
    func testBudgetIncludesOutputReservation() throws {
        try ProbePolicy.validate(tokens: 1792)
        XCTAssertThrowsError(try ProbePolicy.validate(tokens: 1793))
        XCTAssertThrowsError(try ProbePolicy.validate(tokens: 0))
        XCTAssertThrowsError(try ProbePolicy.validate(tokens: Int.max))
    }
    func testFirstStopReasonSurvivesCancellation() {
        let control = ProbeControl()
        control.stop(.memoryWarning); control.stop(.cancelled); control.stop(.background)
        XCTAssertEqual(control.reason, .memoryWarning)
        XCTAssertThrowsError(try control.check()) { XCTAssertEqual($0 as? ProbeFailure, .memoryWarning) }
    }
    func testConcurrentStopIsStable() {
        let control = ProbeControl()
        control.stop(.background)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in control.stop(.cancelled) }
        XCTAssertEqual(control.reason, .background)
    }
    func testManifestRejectsPathTraversalAndDuplicateFiles() {
        for names in [["../model"], ["a/b"], [""], ["config", "config"]] {
            let manifest = ModelManifest(repository: "mlx-community/Qwen3.5-2B-4bit", revision: String(repeating: "a", count: 40),
                files: names.map { .init(name: $0, size: 1, sha256: String(repeating: "a", count: 64)) })
            XCTAssertThrowsError(try manifest.validate())
        }
    }
    func testManifestRejectsInvalidHashAndEmptyFiles() {
        let manifest = ModelManifest(repository: "mlx-community/Qwen3.5-2B-4bit", revision: String(repeating: "a", count: 40),
            files: [.init(name: "model", size: 0, sha256: "bad")])
        XCTAssertThrowsError(try manifest.validate())
    }
    func testURLUsesPinnedRevisionAndModelScope() throws {
        let file = ModelManifest.File(name: "config.json", size: 10, sha256: String(repeating: "a", count: 64))
        let revision = String(repeating: "b", count: 40)
        let manifest = ModelManifest(repository: "mlx-community/Qwen3.5-2B-4bit", revision: revision, files: [file])
        try manifest.validate()
        XCTAssertEqual(manifest.url(for: file).host, "modelscope.cn")
        XCTAssertTrue(manifest.url(for: file).path.contains(revision))
        XCTAssertEqual(manifest.totalBytes, 10)
    }
    func testReportContainsNoConversationFields() throws {
        let report = ProbeReport(id: UUID(), date: Date(), device: "iPhone15", os: "17", revision: "fixed")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["id", "date", "device", "os", "revision", "runtime", "inputTokens", "outputTokens", "samples"]))
    }
    func testPeakIgnoresUnavailableFootprint() {
        var report = ProbeReport(id: UUID(), date: Date(), device: "test", os: "17", revision: "fixed")
        report.samples = [nil, UInt64(50), UInt64(20)].map {
            MemoryPoint(stage: "test", elapsed: 0, footprint: $0, available: 0, mlxActive: 0, mlxCache: 0, mlxPeak: 0)
        }
        XCTAssertEqual(report.sampledPeakFootprint, 50)
    }
}
