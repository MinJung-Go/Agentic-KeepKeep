import XCTest
import CryptoKit
import UIKit
import ImageIO
@testable import AgenticKeepKeep

final class LocalModelInstallTests: XCTestCase {
    @MainActor
    func testModelUpgradeDoesNotReuseOldDownloadIdentityOrIntent() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set("old-2b-task", forKey: "localMilo.mlx.backgroundGeneration")
        defaults.set(true, forKey: "localMilo.mlx.backgroundDownloadActive")
        XCTAssertNil(defaults.string(forKey: LocalModelStore.generationKey))
        XCTAssertFalse(defaults.bool(forKey: LocalModelStore.activeKey))
        XCTAssertTrue(LocalModelStore.generationKey.hasSuffix(LocalModelManifest.revision))
        XCTAssertTrue(LocalModelStore.activeKey.hasSuffix(LocalModelManifest.revision))
        let oldTask = LocalDownloadPolicy.descriptor(generation: "old-2b-task", file: "model.safetensors")
        XCTAssertNil(LocalDownloadPolicy.file(in: oldTask, generation: "new-08b-task", allowed: LocalModelManifest.files.map(\.name)))
    }
    func testOldModelReadyMarkerIsRejectedEvenWithMatchingFileSizes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Sparse fixtures exercise size checks without allocating model contents.
        for file in LocalModelManifest.files {
            let url = directory.appendingPathComponent(file.name)
            try Data().write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(file.bytes))
            try handle.close()
        }
        let marker = directory.appendingPathComponent("ready")
        try Data(LocalModelManifest.revision.utf8).write(to: marker)
        XCTAssertTrue(LocalModelManifest.isInstalled(at: directory))
        try Data("mlx-ffa48c63955c56e22d76c1b2acd9b89e26310618".utf8).write(to: marker)
        XCTAssertFalse(LocalModelManifest.isInstalled(at: directory))
    }
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
        XCTAssertLessThanOrEqual(max(image.width, image.height), 384)
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
        XCTAssertEqual(LocalModelManifest.requiredDownloadSpace(existingSizes: [files[0].name: files[0].bytes]), LocalModelManifest.totalBytes - files[0].bytes + 268_435_456)
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
        XCTAssertEqual(LocalModelManifest.files.count, 8)
        XCTAssertTrue(LocalModelManifest.files.contains { $0.name == "model.safetensors" })
        XCTAssertTrue(LocalModelManifest.files.contains { $0.name == "preprocessor_config.json" })
        XCTAssertFalse(LocalModelManifest.files.contains { $0.name.hasSuffix(".gguf") })
        XCTAssertTrue(LocalModelManifest.revision.hasPrefix("mlx-"))
        XCTAssertEqual(LocalModelManifest.totalBytes, 645303999)
        for file in LocalModelManifest.files {
            XCTAssertEqual(file.sha256.count, 64)
            XCTAssertEqual(file.url.host, "modelscope.cn")
            XCTAssertTrue(file.url.path.contains(LocalModelManifest.modelScopeRevision))
            XCTAssertTrue(file.url.path.contains("/Qwen3.5-0.8B-4bit/"))
            XCTAssertFalse(file.url.path.contains("/main/"))
        }
    }
    func testLocalWindowDoesNotOverwriteCloudPreference() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LLMSettings(defaults: defaults)
        settings.coachContextWindow = 65_536
        settings.useLocalModel = true
        XCTAssertEqual(settings.coachPolicy.window, 16_384)
        XCTAssertEqual(settings.coachPolicy.outputReserve, LocalMLXPolicy.maximumOutput)
        settings.useLocalModel = false
        XCTAssertEqual(settings.coachPolicy.window, 65_536)
        XCTAssertEqual(settings.coachContextWindow, 65_536)
    }
    func testLocalModeNeverRequiresAPIKeyOrFallsBackWhenMissing() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = LLMSettings(defaults: defaults)
        settings.useLocalModel = true
        XCTAssertTrue(settings.supportsWebSearch)
        XCTAssertEqual(settings.coachPolicy.window, 16_384)
        XCTAssertEqual(settings.coachPolicy.window, LocalMLXPolicy.context)
        XCTAssertEqual(settings.coachPolicy.inputCap, LocalMLXPolicy.context)
        XCTAssertEqual(try settings.coachPolicy.inputLimit(), 13_824)
        XCTAssertEqual(settings.coachPolicy.outputReserve, 2048)
        if !LocalModelManifest.isInstalled() {
            XCTAssertThrowsError(try settings.makeClient()) { XCTAssertTrue($0 is LocalMiloError) }
        } else {
            XCTAssertTrue(try settings.makeClient() is LocalLLMClient)
        }
    }
}
