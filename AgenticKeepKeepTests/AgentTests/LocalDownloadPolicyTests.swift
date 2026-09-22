import XCTest
@testable import AgenticKeepKeep

final class LocalDownloadPolicyTests: XCTestCase {
    func testDeletedInstallationCannotAcceptOldCallback() {
        let id = LocalDownloadPolicy.descriptor(generation: "old", file: "vision.gguf")
        XCTAssertNil(LocalDownloadPolicy.file(in: id, generation: "new", allowed: ["vision.gguf"]))
        XCTAssertEqual(LocalDownloadPolicy.file(in: id, generation: "old", allowed: ["vision.gguf"]), "vision.gguf")
    }
    func testDescriptorRejectsUnknownFilesAndTraversal() {
        for id in [nil, "", "run|../ready", "run|text.gguf|extra", "other|text.gguf"] as [String?] {
            XCTAssertNil(LocalDownloadPolicy.file(in: id, generation: "run", allowed: ["text.gguf"]))
        }
    }
    func testSystemRelaunchAdoptsRunningTasksBeforeVerifying() {
        XCTAssertEqual(LocalDownloadPolicy.recover(installed: false, activeTasks: 1, completeFiles: 1, expectedFiles: 2, hasDirectory: true), .downloading)
    }
    func testCompletedDownloadsRequireVerificationNotReady() {
        XCTAssertEqual(LocalDownloadPolicy.recover(installed: false, activeTasks: 0, completeFiles: 2, expectedFiles: 2, hasDirectory: true), .verify)
    }
    func testForceQuitMissingTasksDoesNotSilentlyStartNewTransfer() {
        XCTAssertEqual(LocalDownloadPolicy.recover(installed: false, activeTasks: 0, completeFiles: 1, expectedFiles: 2, hasDirectory: true), .paused)
    }
    func testInstalledAndFreshStates() {
        XCTAssertEqual(LocalDownloadPolicy.recover(installed: true, activeTasks: 0, completeFiles: 2, expectedFiles: 2, hasDirectory: true), .installed)
        XCTAssertEqual(LocalDownloadPolicy.recover(installed: false, activeTasks: 0, completeFiles: 0, expectedFiles: 2, hasDirectory: false), .absent)
    }
    func testProgressWeightsTwoComponentsAndIgnoresStaleFiles() {
        XCTAssertEqual(LocalDownloadPolicy.progress(bytes: ["text": 50, "vision": 50, "old": 999], expected: ["text": 100, "vision": 50]), 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(LocalDownloadPolicy.progress(bytes: ["text": -1, "vision": 500], expected: ["text": 100, "vision": 50]), 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(LocalDownloadPolicy.progress(bytes: [:], expected: [:]), 0)
    }
}
