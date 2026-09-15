import XCTest
@testable import AgenticKeepKeep

final class HomeInputRouterTests: XCTestCase {
    func testEmptyDoesNotOpenAnything() {
        XCTAssertEqual(HomeInputRouter.destination(text: " \n", hasPhoto: false), .empty)
    }
    func testQueriesNeverBecomeRecords() {
        for text in ["昨天练了什么", "今天吃了哪些东西", "上次做了几组", "今天走了多少步", "查一下昨天吃了什么", "体重怎么一直不变", "卧推60kg 4×8可以吗", "删除昨天的记录", "不要记录我吃了面条"] {
            XCTAssertEqual(HomeInputRouter.destination(text: text, hasPhoto: false), .chat, text)
        }
    }
    func testExplicitRecordsOpenConfirmation() {
        for text in ["卧推60kg 4×8", "深蹲 100kg 5×5", "午饭吃了牛肉面", "帮我记录今天的训练", "跑步5公里", "体重 68kg"] {
            XCTAssertEqual(HomeInputRouter.destination(text: text, hasPhoto: false), .record, text)
        }
    }
    func testAmbiguousInputRequiresChoice() {
        for text in ["今天跑步", "午饭", "卧推", "体重"] {
            XCTAssertEqual(HomeInputRouter.destination(text: text, hasPhoto: false), .choose, text)
        }
    }
    func testPhotosUseVisionConfirmationWithOrWithoutCaption() {
        for text in ["", "午饭", "这是什么食物？"] {
            XCTAssertEqual(HomeInputRouter.destination(text: text, hasPhoto: true), .record)
        }
    }
    func testConversationAndPlanningStayInChat() {
        for text in ["我有点累", "一起制定训练计划", "你好", "帮我修改明天的训练"] {
            XCTAssertEqual(HomeInputRouter.destination(text: text, hasPhoto: false), .chat, text)
        }
    }
}
