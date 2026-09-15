import XCTest
import SwiftData
@testable import AgenticKeepKeep

@MainActor
final class HomeLoggingTests: XCTestCase {
    func testHomeTextStartsSubmissionAndIsNotResentWhenSheetReappears() async throws {
        let container = try AppModelContainer.inMemory()
        let context = ModelContext(container)
        let state = AppState()
        state.pendingLogText = "深蹲100kg 5×5"
        let model = makeUnconfiguredModel()
        await model.submitHomeInput(from: state, context: context)
        XCTAssertEqual(model.turns.first?.text, "深蹲100kg 5×5")
        XCTAssertEqual(model.turns.count, 2, "已实际处理，未配置模型时返回失败结果")
        XCTAssertTrue(model.inputText.isEmpty)
        XCTAssertTrue(state.pendingLogText.isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RawNote>()), 1)
        await model.submitHomeInput(from: state, context: context)
        XCTAssertEqual(model.turns.count, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RawNote>()), 1)
    }

    func testPhotoOnlyAndCaptionAreSubmittedTogetherAndConsumedOnce() async throws {
        let container = try AppModelContainer.inMemory()
        let context = ModelContext(container)
        for caption in ["", "午饭，一碗米饭"] {
            let state = AppState()
            let photo = Data([1, 2, 3])
            state.pendingLogText = caption
            state.pendingLogPhoto = photo
            let model = makeUnconfiguredModel()
            await model.submitHomeInput(from: state, context: context)
            XCTAssertEqual(model.turns.first?.text, caption)
            XCTAssertEqual(model.turns.first?.photoData, photo)
            XCTAssertEqual(model.turns.count, 2)
            XCTAssertNil(state.pendingLogPhoto)
            XCTAssertTrue(state.pendingLogText.isEmpty)
            await model.submitHomeInput(from: state, context: context)
            XCTAssertEqual(model.turns.count, 2)
        }
    }

    private func makeUnconfiguredModel() -> LoggingViewModel {
        let suite = "HomeLoggingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = LLMSettings(defaults: defaults)
        // 独立配置禁用网络，不修改 Keychain 中的 API Key。
        settings.modelName = ""
        defaults.removePersistentDomain(forName: suite)
        return LoggingViewModel(settings: settings)
    }
}
