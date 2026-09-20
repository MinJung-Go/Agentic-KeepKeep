import Foundation
import MiloInferenceCore

/// Actual tokenizer enforcement is separate from the coach's pruning estimate.
enum LocalMLXPolicy {
    static let context = 16_384
    static var contextLabel: String { "\(context / 1024)K" }
    static let maximumOutput = 2048
    static var budget: InferenceBudget { InferenceBudget(context: context, maximumOutput: maximumOutput) }
    static func outputLimit(_ requested: Int?) -> Int { min(maximumOutput, max(1, requested ?? maximumOutput)) }
    static func validate(input: Int, output: Int) throws {
        do { try budget.validate(input: input, output: output) }
        catch { throw LocalMiloError.budget }
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
        _ = try normalizedJSON(text)
    }
    static func normalizedJSON(_ text: String) throws -> String {
        var content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.hasPrefix("```") {
            guard let newline = content.firstIndex(of: "\n"), content.hasSuffix("```") else { throw LocalMiloError.malformedTool }
            let opening = content[..<newline].trimmingCharacters(in: .whitespaces).lowercased()
            guard opening == "```json" || opening == "```" else { throw LocalMiloError.malformedTool }
            let body = content[content.index(after: newline)...]
            guard body.count >= 3 else { throw LocalMiloError.malformedTool }
            content = String(body.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let value = JSONValue.parse(content), value.objectValue != nil || value.arrayValue != nil else { throw LocalMiloError.malformedTool }
        return content
    }
}
