import XCTest
@testable import AgenticKeepKeep

final class MarkdownFormatterTests: XCTestCase {

    func testStripsHeadingMarkers() {
        XCTAssertEqual(MarkdownFormatter.normalize("## 今日建议"), "今日建议")
        XCTAssertEqual(MarkdownFormatter.normalize("### 训练"), "训练")
        XCTAssertEqual(MarkdownFormatter.normalize("#加粗不是标题"), "#加粗不是标题", "没有空格的不算标题")
    }

    func testConvertsBullets() {
        XCTAssertEqual(MarkdownFormatter.normalize("- 深蹲 5×5"), "• 深蹲 5×5")
        XCTAssertEqual(MarkdownFormatter.normalize("* 卧推 4×8"), "• 卧推 4×8")
        XCTAssertEqual(MarkdownFormatter.normalize("  - 缩进项"), "  • 缩进项")
    }

    func testPreservesInlineMarkdown() {
        // 加粗/斜体/代码要原样保留，交给 AttributedString 解析
        XCTAssertEqual(MarkdownFormatter.normalize("建议**减载 15%**"), "建议**减载 15%**")
        XCTAssertEqual(MarkdownFormatter.normalize("用 `create_plan` 工具"), "用 `create_plan` 工具")
    }

    func testPreservesLineBreaks() {
        let input = "第一行\n\n第三行"
        XCTAssertEqual(MarkdownFormatter.normalize(input), "第一行\n\n第三行")
    }

    func testKeepsNumberedLists() {
        XCTAssertEqual(MarkdownFormatter.normalize("1. 热身\n2. 主项"), "1. 热身\n2. 主项")
    }

    func testPlainTextUnchanged() {
        let text = "昨晚只睡了5小时，今天练不动"
        XCTAssertEqual(MarkdownFormatter.normalize(text), text)
    }

    func testEmptyString() {
        XCTAssertEqual(MarkdownFormatter.normalize(""), "")
    }

    // MARK: - 块级切分（FR16.2）

    func testBlocksSplitHeadingsListsAndDividers() {
        let blocks = MarkdownFormatter.blocks(from: """
        ## 本周建议
        先把下肢日减载 20%。

        - 深蹲 5×5
        - 卧推 4×8
        ---
        1. 热身
        2. 主项
        """)

        XCTAssertEqual(blocks, [
            .heading("本周建议"),
            .paragraph("先把下肢日减载 20%。"),
            .bullet("深蹲 5×5"),
            .bullet("卧推 4×8"),
            .divider,
            .numbered(marker: "1.", text: "热身"),
            .numbered(marker: "2.", text: "主项"),
        ])
    }

    func testBlocksMergeConsecutiveLinesIntoOneParagraph() {
        let blocks = MarkdownFormatter.blocks(from: "第一行\n第二行")
        XCTAssertEqual(blocks, [.paragraph("第一行\n第二行")], "连续普通行应当并成一段，而不是两段")
    }

    func testBlocksIgnoreBlankLines() {
        let blocks = MarkdownFormatter.blocks(from: "上\n\n下")
        XCTAssertEqual(blocks, [.paragraph("上"), .paragraph("下")])
    }

    func testHeadingWithoutSpaceIsNotAHeading() {
        // 「#加粗不是标题」——没有空格的不算
        XCTAssertEqual(MarkdownFormatter.blocks(from: "#不是标题"), [.paragraph("#不是标题")])
    }

    func testDividerVariants() {
        XCTAssertEqual(MarkdownFormatter.blocks(from: "---"), [.divider])
        XCTAssertEqual(MarkdownFormatter.blocks(from: "***"), [.divider])
        XCTAssertEqual(MarkdownFormatter.blocks(from: "- - -"), [.divider], "带空格的也算分隔线")
        XCTAssertEqual(MarkdownFormatter.blocks(from: "--"), [.paragraph("--")], "两个连字符太短，不算")
    }

    func testBlocksKeepInlineMarkdownIntact() {
        // 块内语法原样留着，交给 AttributedString
        XCTAssertEqual(MarkdownFormatter.blocks(from: "- **减载** 15%"), [.bullet("**减载** 15%")])
    }

    func testBlocksOnEmptyInput() {
        XCTAssertTrue(MarkdownFormatter.blocks(from: "").isEmpty)
        XCTAssertTrue(MarkdownFormatter.blocks(from: "\n\n").isEmpty)
    }

    // MARK: - 渲染

    func testAttributedStringRendersBold() {
        let attributed = MarkdownText.attributedString(from: "建议**减载**")

        let hasBold = attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        XCTAssertTrue(hasBold, "**加粗** 应当被解析成粗体")
    }

    func testAttributedStringKeepsTextContent() {
        let attributed = MarkdownText.attributedString(from: "## 标题\n- 项目")
        let plain = String(attributed.characters)

        XCTAssertTrue(plain.contains("标题"))
        XCTAssertTrue(plain.contains("项目"))
        XCTAssertFalse(plain.contains("#"), "标题标记应当被去掉")
    }

    func testAttributedStringFallsBackForBrokenMarkdown() {
        // 未闭合的标记不应导致内容丢失
        let attributed = MarkdownText.attributedString(from: "**没闭合的加粗")
        XCTAssertTrue(String(attributed.characters).contains("没闭合的加粗"))
    }
}
