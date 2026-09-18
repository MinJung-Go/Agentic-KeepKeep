import XCTest
import CryptoKit
import UIKit
import ImageIO
@testable import AgenticKeepKeep

final class LocalModelInstallTests: XCTestCase {
    func testCancellationPreservesFirstReason() {
        let memory = LocalCancellation()
        memory.cancel(reason: .memoryPressure)
        memory.cancel()
        XCTAssertEqual(memory.failure as? LocalMiloError, .memoryPressure)
        let manual = LocalCancellation()
        manual.cancel()
        manual.cancel(reason: .backgrounded)
        XCTAssertTrue(manual.failure is CancellationError)
        let background = LocalCancellation()
        background.cancel(reason: .backgrounded)
        XCTAssertEqual(background.failure as? LocalMiloError, .backgrounded)
    }
    func testImagePreprocessingRejectsInvalidAndMultipleImages() throws {
        XCTAssertThrowsError(try LocalInferenceWorker.image(["not base64"]))
        XCTAssertThrowsError(try LocalInferenceWorker.image([Data("not an image".utf8).base64EncodedString()]))
        XCTAssertThrowsError(try LocalInferenceWorker.image(["one", "two"]))
        XCTAssertTrue(try LocalInferenceWorker.image([]).isEmpty)
    }
    func testImagePreprocessingBoundsPixels() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1800, height: 900))
        let data = renderer.jpegData(withCompressionQuality: 0.8) { ctx in
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1800, height: 900))
        }
        let result = try LocalInferenceWorker.image([data.base64EncodedString()])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(max(image.width, image.height), 768)
        XCTAssertEqual(image.width, image.height * 2)
    }
    func testHashVerificationCanBeCancelled() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data(repeating: 1, count: 4096)
        try data.write(to: url)
        let file = LocalModelFile(name: "test.gguf", bytes: Int64(data.count), sha256: "irrelevant")
        XCTAssertThrowsError(try LocalModelManifest.verify(url, file: file, isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }
    func testStorageBudgetIncludesMissingAndTruncatedComponents() {
        let files = LocalModelManifest.files
        XCTAssertEqual(LocalModelManifest.requiredDownloadSpace(existingSizes: [:]), LocalModelManifest.totalBytes + 268_435_456)
        XCTAssertEqual(LocalModelManifest.requiredDownloadSpace(existingSizes: [files[0].name: files[0].bytes]), files[1].bytes + 268_435_456)
        XCTAssertEqual(LocalModelManifest.requiredDownloadSpace(existingSizes: [files[0].name: 1]), LocalModelManifest.totalBytes + 268_435_456)
    }
    @MainActor
    func testBackgroundSessionSeparatesCellularConsent() {
        let wifi = LocalModelStore.configuration(cellular: false)
        let cellular = LocalModelStore.configuration(cellular: true)
        XCTAssertFalse(wifi.allowsCellularAccess)
        XCTAssertTrue(cellular.allowsCellularAccess)
        XCTAssertNotEqual(wifi.identifier, cellular.identifier)
        XCTAssertEqual(wifi.identifier, LocalModelStore.configuration(cellular: false).identifier)
        XCTAssertTrue(wifi.sessionSendsLaunchEvents)
        XCTAssertFalse(wifi.isDiscretionary)
    }
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
            XCTAssertEqual(file.url.host, "modelscope.cn")
            XCTAssertTrue(file.url.path.contains(LocalModelManifest.modelScopeRevision))
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
