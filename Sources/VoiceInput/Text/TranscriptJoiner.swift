import Foundation

/// 实时模式下，各段识别结果按顺序拼接。识别文字本身不做任何改动。
///
/// 唯一的处理：两段都是英文等用空格分词的文字时（例如 "Hello world" + "how are you"），
/// 中间补一个空格，避免两个单词粘在一起。中文、日文不补任何字符（不加逗号）。
enum TranscriptJoiner {
    static func separator(between previous: String, and next: String) -> String {
        guard let last = previous.last, let first = next.first else { return "" }
        if last.isWhitespace || first.isWhitespace { return "" }
        if isCJK(last) || isCJK(first) { return "" }
        return " "
    }

    /// 汉字、假名、全角标点：这类文字之间不用空格
    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x303F,   // CJK 符号和标点（。、「」等）
                 0x3040...0x30FF,   // 平假名、片假名
                 0x3400...0x4DBF,   // 汉字扩展 A
                 0x4E00...0x9FFF,   // 常用汉字
                 0xF900...0xFAFF,   // 兼容汉字
                 0xFF00...0xFFEF:   // 全角字符（，！？等）
                return true
            default:
                return false
            }
        }
    }
}
