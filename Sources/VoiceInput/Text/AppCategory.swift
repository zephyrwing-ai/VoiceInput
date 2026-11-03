import Foundation

/// 当前输入的 App 属于哪一类。目前只用于日志排查，不会影响写入的文字。
enum AppCategory: String, Codable, CaseIterable {
    case chat, email, document, aiChat, code, general

    var displayName: String {
        switch self {
        case .chat: return "即时通讯"
        case .email: return "邮件"
        case .document: return "文档 / 笔记"
        case .aiChat: return "AI 对话"
        case .code: return "代码 / 终端"
        case .general: return "通用"
        }
    }

    // 内置分类表。bundle ID 以实际为准，后续可以改成可下发的配置文件。
    private static let byBundleID: [String: AppCategory] = [
        "com.tencent.xinWeChat": .chat,
        "com.tinyspeck.slackmacgap": .chat,
        "com.apple.MobileSMS": .chat,
        "com.tencent.qq": .chat,
        "com.electron.lark": .chat,          // 飞书（待确认）
        "com.alibaba.DingTalkMac": .chat,    // 钉钉（待确认）
        "ru.keepcoder.Telegram": .chat,
        "com.apple.mail": .email,
        "com.microsoft.Outlook": .email,
        "com.apple.Notes": .document,
        "notion.id": .document,
        "md.obsidian": .document,
        "com.microsoft.Word": .document,
        "com.apple.iWork.Pages": .document,
        "com.openai.chat": .aiChat,
        "com.anthropic.claudefordesktop": .aiChat,
        "com.apple.Terminal": .code,
        "com.googlecode.iterm2": .code,
        "com.microsoft.VSCode": .code,
        "com.apple.dt.Xcode": .code,
        "com.todesktop.230313mzl4w4u92": .code,  // Cursor（待确认）
    ]

    private static let byDomain: [(suffix: String, category: AppCategory)] = [
        ("mail.google.com", .email), ("outlook.live.com", .email), ("outlook.office.com", .email),
        ("chatgpt.com", .aiChat), ("claude.ai", .aiChat), ("gemini.google.com", .aiChat),
        ("docs.google.com", .document), ("notion.so", .document), ("feishu.cn", .document),
        ("github.com", .code),
    ]

    static func classify(bundleID: String?, webHost: String?) -> AppCategory {
        if let host = webHost?.lowercased(),
           let match = byDomain.first(where: { host == $0.suffix || host.hasSuffix("." + $0.suffix) }) {
            return match.category
        }
        guard let bundleID else { return .general }
        return byBundleID[bundleID] ?? .general
    }
}
