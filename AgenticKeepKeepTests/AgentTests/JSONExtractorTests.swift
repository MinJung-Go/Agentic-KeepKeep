import XCTest
@testable import AgenticKeepKeep

final class JSONExtractorTests: XCTestCase {

    private struct Sample: Decodable, Equatable {
        var name: String
        var value: Int
    }

    func testExtractsPlainObject() throws {
        let data = try JSONExtractor.extract(from: #"{"name":"深蹲","value":5}"#)
        let sample = try JSONDecoder().decode(Sample.self, from: data)
        XCTAssertEqual(sample, Sample(name: "深蹲", value: 5))
    }

    func testStripsCodeFence() throws {
        let text = """
        ```json
        {"name":"卧推","value":8}
        ```
        """
        let sample = try JSONExtractor.decode(Sample.self, from: text)
        XCTAssertEqual(sample.value, 8)
    }

    func testStripsSurroundingProse() throws {
        let text = #"好的，这是解析结果：{"name":"硬拉","value":3} 希望有帮助！"#
        let sample = try JSONExtractor.decode(Sample.self, from: text)
        XCTAssertEqual(sample.name, "硬拉")
    }

    func testExtractsArray() throws {
        let text = #"[{"name":"a","value":1},{"name":"b","value":2}]"#
        let data = try JSONExtractor.extract(from: text)
        let samples = try JSONDecoder().decode([Sample].self, from: data)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[1].name, "b")
    }

    func testThrowsWhenNoJSON() {
        XCTAssertThrowsError(try JSONExtractor.extract(from: "没有 JSON 的普通句子"))
    }

    func testThrowsWhenUnterminated() {
        XCTAssertThrowsError(try JSONExtractor.extract(from: #"{"name":"深蹲""#))
    }

    // MARK: - 宽松解码

    func testLenientNumbersFromStrings() throws {
        let json = #"{"weightKg":"100.5","reps":"8"}"#
        let container = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
        XCTAssertEqual(container["weightKg"]?.doubleValue, 100.5)
        XCTAssertEqual(container["reps"]?.intValue, 8)
    }

    func testJSONValueRoundTrip() throws {
        let value = JSONSchema.object(
            properties: ["name": JSONSchema.string(description: "动作名")],
            required: ["name"]
        )
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        let properties = try XCTUnwrap(decoded.objectValue?["properties"]?.objectValue)
        XCTAssertEqual(properties["name"]?.objectValue?["type"]?.stringValue, "string")
    }
}
