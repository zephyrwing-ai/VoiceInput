import Foundation

/// 不依赖模型的规则清理。每一段实时上屏的文字都会先经过这里。
enum RuleCleaner {
    struct Options {
        var convertToSimplified = true
    }

    static func clean(_ raw: String, options: Options = Options()) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isHallucination(text) else { return "" }

        if options.convertToSimplified {
            text = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
        }
        // 整句只有"嗯""嗯嗯"时保留：在聊天里这是有效的回复
        if isOnlyFiller(text) { return text }

        text = replace(text, #"(嗯+|呃+|(?i:\bu+h+\b|\bu+m+\b|\bem{2,}\b))[，,、。．.\s]*"#, with: "")
        text = replace(text, #"(\p{Han}{2,4})\1+"#, with: "$1")            // 再进行再进行 → 再进行
        text = replace(text, #"(\p{Han})([A-Za-z0-9])"#, with: "$1 $2")     // 中英文之间加空格
        text = replace(text, #"([A-Za-z0-9])(\p{Han})"#, with: "$1 $2")
        text = replace(text, #"([，。！？、；：])\1+"#, with: "$1")          // 重复标点
        text = replace(text, #"^[，。、；：,.\s]+"#, with: "")                // 句首残留标点
        text = replace(text, #"[ \t]{2,}"#, with: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 两段文字拼接时，中间需要补的分隔符（实时上屏时，下一段到来再给上一段补标点）
    static func separator(between previous: String, and next: String) -> String {
        guard let last = previous.last, let first = next.first else { return "" }
        if isPunctuationOrSpace(last) || isPunctuationOrSpace(first) { return "" }
        if isHan(last) || isHan(first) { return "，" }
        return " "
    }

    /// 整段结束时补句末标点。聊天和代码类不补。
    static func finalizeEnding(_ text: String, category: AppCategory) -> String {
        guard let last = text.last, category != .chat, category != .code else { return text }
        if isPunctuationOrSpace(last) { return text }
        return text + (text.contains(where: isHan) ? "。" : ".")
    }

    // MARK: - Whisper 在静音或噪声上常见的"幻觉"输出
    // 只收录正常说话时几乎不会出现的句子；"Thank you" 这类日常用语不收录，避免误删。

    private static let hallucinations: [String] = [
        "谢谢观看", "感谢观看", "谢谢大家观看", "请不吝点赞订阅转发打赏支持明镜与点点栏目",
        "字幕由amara.org社区提供", "优优独播剧场", "thankyouforwatching", "thanksforwatching",
    ]

    static func isHallucination(_ text: String) -> Bool {
        let normalized = text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
        guard !normalized.isEmpty else { return true }
        if normalized.contains("字幕") && (normalized.contains("提供") || normalized.contains("制作")) { return true }
        return hallucinations.contains { normalized == $0 || (normalized.count > 6 && normalized.contains($0) && $0.count > 6) }
    }

    // MARK: - 工具

    private static func isOnlyFiller(_ text: String) -> Bool {
        let stripped = text.filter { !$0.isPunctuation && !$0.isWhitespace }
        return !stripped.isEmpty && stripped.allSatisfy { $0 == "嗯" || $0 == "呃" }
    }

    static func isHan(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    private static func isPunctuationOrSpace(_ c: Character) -> Bool {
        c.isPunctuation || c.isWhitespace || c.isSymbol
    }

    private static func replace(_ text: String, _ pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
