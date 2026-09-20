import Foundation

/// 从模型输出中提取 JSON（容忍代码围栏、前后解释文字）
enum JSONExtractor {

    static func extract(from text: String) throws -> Data {
        var content = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 去掉 ```json ... ``` 围栏
        if content.hasPrefix("```") {
            if let firstNewline = content.firstIndex(of: "\n") {
                content = String(content[content.index(after: firstNewline)...])
            }
            if let closing = content.range(of: "```", options: .backwards) {
                content = String(content[content.startIndex..<closing.lowerBound])
            }
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let start = content.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            throw AgentError.invalidJSON("未找到 JSON 起始符号")
        }

        let open: Character = content[start]
        let close: Character = (open == "{") ? "}" : "]"

        guard let end = content.lastIndex(of: close), end > start else {
            throw AgentError.invalidJSON("未找到 JSON 结束符号")
        }

        let slice = String(content[start...end])
        guard let data = slice.data(using: .utf8) else {
            throw AgentError.invalidJSON("编码失败")
        }
        return data
    }

    /// 直接解码为 Decodable
    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let data = try extract(from: text)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw AgentError.invalidJSON(decodingDetail(error))
        }
    }

    /// Include schema paths, never response values or arbitrary decoder descriptions.
    static func decodingDetail(_ error: DecodingError) -> String {
        let path: [CodingKey]
        let reason: String
        switch error {
        case .keyNotFound(let key, let context):
            path = context.codingPath + [key]; reason = "缺少必填字段"
        case .typeMismatch(_, let context):
            path = context.codingPath; reason = "字段类型不符合记录结构"
        case .valueNotFound(_, let context):
            path = context.codingPath; reason = "必填字段不能为 null"
        case .dataCorrupted(let context):
            path = context.codingPath; reason = "JSON 内容不完整或格式不正确"
        @unknown default:
            return "JSON 格式不符合要求"
        }
        let location = path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        return "\(location.isEmpty ? "根节点" : location)：\(reason)"
    }
}

/// 宽松解码：模型常把数字写成字符串、或漏字段，这里统一容错
enum Lenient {

    static func double<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return Double(value) }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func int<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let value = Int(trimmed) { return value }
            if let value = Double(trimmed) { return Int(value) }
        }
        return nil
    }

    static func string<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return String(value) }
        return nil
    }

    static func strings<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> [String]? {
        if let value = try? container.decodeIfPresent([String].self, forKey: key) { return value }
        if let single = try? container.decodeIfPresent(String.self, forKey: key) {
            return [single]
        }
        return nil
    }
}
