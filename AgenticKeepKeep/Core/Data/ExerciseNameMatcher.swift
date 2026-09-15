import Foundation

/// 课程表动作名称的机械归一化，不依赖第三方目录。
enum ExerciseNameMatcher {
    static func normalize(_ text: String) -> String {
        var out = String.UnicodeScalarView()

        for original in text.lowercased().unicodeScalars {
            // 先做全角 → 半角（！-～ 与 Ａ-Ｚ 在这一段里），**再**判断要不要丢。
            // 顺序不能反：反了的话「（」会先被转成「(」再溜进结果里。
            var scalar = original
            if (0xFF01...0xFF5E).contains(scalar.value),
               let half = Unicode.Scalar(scalar.value - 0xFEE0) {
                scalar = half
            }

            if scalar.value == 0x3000 { continue }          // 全角空格
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if CharacterSet.punctuationCharacters.contains(scalar) { continue }

            out.append(scalar)
        }

        return String(out)
    }

}
