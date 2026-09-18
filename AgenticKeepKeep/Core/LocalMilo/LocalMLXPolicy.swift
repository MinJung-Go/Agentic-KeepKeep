import Foundation

/// Actual tokenizer enforcement is separate from the coach's pruning estimate.
enum LocalMLXPolicy {
    static let context = 8192
    static let maximumOutput = 1024
    static func outputLimit(_ requested: Int?) -> Int { min(maximumOutput, max(1, requested ?? maximumOutput)) }
    static func validate(input: Int, output: Int) throws {
        guard input > 0, output > 0, output <= maximumOutput, input <= context - output else { throw LocalMiloError.budget }
    }
    /// The rendered ChatML has already escaped user-supplied control tokens.
    /// VLM applies its own chat template, so preserve roles instead of wrapping
    /// the full transcript in a second user message.
    static func visionMessages(_ rendered: String) throws -> [[String: String]] {
        let prefix = "<|im_start|>"
        let end = "<|im_end|>"
        let tail = prefix + "assistant\n<think>\n\n</think>\n\n"
        guard rendered.hasSuffix(tail) else { throw LocalMiloError.malformedTool }
        var messages: [[String: String]] = []
        for chunk in rendered.dropLast(tail.count).components(separatedBy: prefix) where !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let newline = chunk.firstIndex(of: "\n"), let boundary = chunk.range(of: end), newline < boundary.lowerBound else { throw LocalMiloError.malformedTool }
            let role = String(chunk[..<newline])
            guard ["system", "user", "assistant"].contains(role) else { throw LocalMiloError.malformedTool }
            var content = String(chunk[chunk.index(after: newline)..<boundary.lowerBound])
            if role == "assistant", content.hasPrefix("<think>\n\n</think>\n\n") { content.removeFirst("<think>\n\n</think>\n\n".count) }
            content = content.replacingOccurrences(of: "<__media__>", with: "<|vision_start|><|image_pad|><|vision_end|>")
            messages.append(["role": role, "content": content])
        }
        return messages
    }
    static func validateJSON(_ text: String) throws {
        guard let value = JSONValue.parse(text), value.objectValue != nil || value.arrayValue != nil else { throw LocalMiloError.malformedTool }
    }
}
