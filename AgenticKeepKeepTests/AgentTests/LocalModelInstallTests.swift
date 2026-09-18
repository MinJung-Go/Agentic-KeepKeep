import XCTest
import CryptoKit
@testable import AgenticKeepKeep

final class LocalModelInstallTests: XCTestCase {
    func testChecksumAcceptsOnlyExpectedBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("trusted model fixture".utf8)
        try data.write(to: url)
        let file = LocalModelFile(name: "test.gguf", bytes: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        XCTAssertNoThrow(try LocalModelManifest.verify(url, file: file))
        try Data(repeating: 0, count: data.count).write(to: url)
        XCTAssertThrowsError(try LocalModelManifest.verify(url, file: file))
        try Data("partial".utf8).write(to: url)
        XCTAssertThrowsError(try LocalModelManifest.verify(url, file: file))
    }
    func testReadyMarkerCannotHideMissingOrWrongSizeVisionFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(LocalModelManifest.revision.utf8).write(to: directory.appendingPathComponent("ready"))
        XCTAssertFalse(LocalModelManifest.isInstalled(at: directory))
        for file in LocalModelManifest.files { try Data("partial".utf8).write(to: directory.appendingPathComponent(file.name)) }
        XCTAssertFalse(LocalModelManifest.isInstalled(at: directory))
    }
    func testPinnedManifestIncludesBothComponentsAndNoFloatingRevision() {
        XCTAssertEqual(LocalModelManifest.files.count, 2)
        XCTAssertEqual(LocalModelManifest.totalBytes, 1_949_063_104)
        for file in LocalModelManifest.files {
            XCTAssertEqual(file.sha256.count, 64)
            XCTAssertEqual(file.url.host, "huggingface.co")
            XCTAssertTrue(file.url.path.contains(LocalModelManifest.revision))
            XCTAssertFalse(file.url.path.contains("/main/"))
        }
    }
    func testLocalModeNeverRequiresAPIKeyOrFallsBackWhenMissing() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = LLMSettings(defaults: defaults)
        settings.useLocalModel = true
        XCTAssertTrue(settings.supportsWebSearch)
        XCTAssertEqual(settings.coachPolicy.window, 8192)
        XCTAssertEqual(settings.coachPolicy.outputReserve, 1024)
        if !LocalModelManifest.isInstalled() {
            XCTAssertThrowsError(try settings.makeClient()) { XCTAssertTrue($0 is LocalMiloError) }
        } else {
            XCTAssertTrue(try settings.makeClient() is LocalLLMClient)
        }
    }
}
