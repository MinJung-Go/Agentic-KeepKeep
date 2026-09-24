import Foundation

enum RealtimeWire {
    static func wav(_ pcm: Data, sampleRate: UInt32 = 16000) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        text("RIFF"); number(UInt32(pcm.count + 36)); text("WAVEfmt ")
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(sampleRate)
        number(sampleRate * 2); number(UInt16(2)); number(UInt16(16)); text("data")
        number(UInt32(pcm.count)); data.append(pcm)
        return data
    }
    static func mode(_ video: Bool) -> [String: Any] {
        ["type": "session.update", "session": ["beta_fields": ["chat_mode": video ? "video_passive" : "audio"]]]
    }
    static func history(_ turns: [(role: String, text: String)]) -> [[String: Any]] {
        turns.suffix(12).filter { ["user", "assistant"].contains($0.role) && !$0.text.isEmpty }.map {
            ["type": "conversation.item.create", "item": ["type": "message", "role": $0.role,
                "content": [["type": $0.role == "user" ? "input_text" : "text", "text": String(decoding: $0.text.utf8.prefix(3000), as: UTF8.self)]]]]
        }
    }
}
