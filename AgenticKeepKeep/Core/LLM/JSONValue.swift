import Foundation

/// 与 wire 格式无关的通用 JSON 值，用于构造 function call 的参数 schema。
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "不支持的 JSON 值")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .integer(let value): return Double(value)
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .integer(let value): return value
        case .number(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

extension JSONValue {
    /// 从原始 JSON 字符串解析（用于 function call 返回的 arguments）
    static func parse(_ raw: String) -> JSONValue? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// 便捷构造：对象
    static func obj(_ pairs: [String: JSONValue]) -> JSONValue { .object(pairs) }

    /// 便捷构造：字符串
    static func str(_ value: String) -> JSONValue { .string(value) }
}

/// JSON Schema 构造辅助（用于 function call 的 parameters）
enum JSONSchema {
    static func object(
        properties: [String: JSONValue],
        required: [String] = []
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) })
        ])
    }

    static func string(description: String? = nil, enumValues: [String]? = nil) -> JSONValue {
        var dict: [String: JSONValue] = ["type": .string("string")]
        if let description { dict["description"] = .string(description) }
        if let enumValues { dict["enum"] = .array(enumValues.map { .string($0) }) }
        return .object(dict)
    }

    static func integer(description: String? = nil) -> JSONValue {
        var dict: [String: JSONValue] = ["type": .string("integer")]
        if let description { dict["description"] = .string(description) }
        return .object(dict)
    }

    static func number(description: String? = nil) -> JSONValue {
        var dict: [String: JSONValue] = ["type": .string("number")]
        if let description { dict["description"] = .string(description) }
        return .object(dict)
    }

    static func array(items: JSONValue, description: String? = nil) -> JSONValue {
        var dict: [String: JSONValue] = ["type": .string("array"), "items": items]
        if let description { dict["description"] = .string(description) }
        return .object(dict)
    }
}
