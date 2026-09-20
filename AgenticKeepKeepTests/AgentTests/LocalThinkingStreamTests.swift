import XCTest
@testable import AgenticKeepKeep

/// LocalOutput 是纯字符串状态机，不依赖 MLX，可在 Linux 便携环境运行。
final class LocalThinkingStreamTests: XCTestCase {
    private func feed(_ chunks: [String], thinking: Bool = true, budget: Int = 1_024)
        -> (output: LocalOutput, reasoning: String, text: String, overflow: Int) {
        var reasoning = "", text = "", overflow = 0
        let output = LocalOutput(thinking: thinking,
                                 onReasoning: { reasoning += $0 }, onText: { text += $0 },
                                 thinkingBudget: budget)
        output.onOverflow = { overflow += 1 }
        var full = ""
        for chunk in chunks {
            full += chunk
            output.replace(full)
        }
        return (output, reasoning, text, overflow)
    }

    func testReasoningEmittedBeforeCloseAndTextAfter() throws {
        let result = feed(["<think>a\n", "b", "</think>答"])
        XCTAssertEqual(result.reasoning, "a\nb")
        XCTAssertEqual(result.text, "答")
        XCTAssertTrue(result.output.thinkingClosed)
        XCTAssertEqual(result.overflow, 0)
    }

    func testPartialCloserNeverLeaksIntoReasoning() throws {
        let result = feed(["<think>abc</thin", "</think>done"])
        XCTAssertEqual(result.reasoning, "abc")
        XCTAssertEqual(result.text, "done")
        XCTAssertTrue(result.output.thinkingClosed)
    }

    func testOverflowFiresOnceAndStopsEmitting() throws {
        let result = feed(["<think>一二三四五六七八九十", "一二三四五六"], budget: 4)
        XCTAssertEqual(result.overflow, 1)
        XCTAssertTrue(result.reasoning.hasPrefix("一二"))
    }

    func testToolTagHoldbackInAnswerPhase() throws {
        let result = feed(["<think>想</think>你好<tool"])
        XCTAssertEqual(result.reasoning, "想")
        XCTAssertEqual(result.text, "你好")
    }

    func testAnswerTextExtractionAndEmptyWhenUnclosed() throws {
        let result = feed(["<think>想</think>  正文  "])
        XCTAssertEqual(result.output.answerText("<think>想</think>正文"), "正文")
        XCTAssertEqual(result.output.answerText("<think>没说完"), "")
    }

    func testFlushEmitsRemainderAfterClose() throws {
        var text = ""
        let output = LocalOutput(thinking: true, onReasoning: { _ in },
                                 onText: { text += $0 }, thinkingBudget: 1_024)
        output.replace("<think>想</think>你好<tool_call>…")
        XCTAssertEqual(text, "你好")
        output.flush("你好")
        XCTAssertEqual(text, "你好")
        output.flush("你好，更长")
        XCTAssertEqual(text, "你好，更长")
    }

    func testNonThinkingOutputStreamsPlainly() throws {
        let result = feed(["你好", "，今天走了多少步"], thinking: false)
        XCTAssertEqual(result.reasoning, "")
        XCTAssertEqual(result.text, "你好，今天走了多少步")
        XCTAssertFalse(result.output.thinkingClosed)
    }
}
