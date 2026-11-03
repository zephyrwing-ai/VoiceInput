import Foundation

/// 识别结果的简繁统一。
///
/// Whisper 对所有中文只用一个语言代码 zh，训练数据里简体和繁体混在一起，同一句普通话有时输出简体、
/// 有时输出繁体；实时模式下每段单独识别，同一句话里也可能一段简体一段繁体。
/// 这里按系统首选语言决定用哪一种：只转换字形，不增删文字、不改标点。
enum ChineseScript: String {
    case simplified
    case traditional

    /// 系统首选语言列表（系统设置 → 通用 → 语言与地区）里排在最前面的中文条目使用的书写形式。
    /// 列表里没有中文时返回 nil，识别结果保持原样。
    ///
    /// 不只看第一项：例如 ["en-JP", "zh-Hans-JP", "ja-JP"] 的界面语言是英文，但用户写中文时用简体。
    static func preferred(from languages: [String] = Locale.preferredLanguages) -> ChineseScript? {
        for identifier in languages {
            let language = Locale.Language(identifier: identifier)
            guard let code = language.languageCode?.identifier, code == "zh" || code == "yue" else { continue }
            // zh-TW、zh-HK 这类没写书写形式的，按地区补全（zh-TW → zh-Hant-TW，zh-CN → zh-Hans-CN）
            let script = language.script ?? Locale.Language(identifier: language.maximalIdentifier).script
            return script?.identifier == "Hant" ? .traditional : .simplified
        }
        return nil
    }

    /// 把文字转换成这种书写形式（使用系统自带的 ICU 转换）。
    /// 含有日文假名时不转换，避免改动日文里的汉字。
    func convert(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: Self.isHan),
              !text.unicodeScalars.contains(where: Self.isKana) else { return text }
        let transform = StringTransform(self == .simplified ? "Hant-Hans" : "Hans-Hant")
        return text.applyingTransform(transform, reverse: false) ?? text
    }

    var displayName: String { self == .simplified ? "简体" : "繁体" }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return true
        default: return false
        }
    }
}
