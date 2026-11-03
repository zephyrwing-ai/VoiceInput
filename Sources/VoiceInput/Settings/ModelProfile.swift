import Foundation

/// 模型的用途
enum ModelRole: String, Codable, CaseIterable, Identifiable {
    case transcription   // 语音识别
    case polish          // 文字润色

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .transcription: return "语音识别"
        case .polish: return "文字润色"
        }
    }
}

/// 接口格式。新增服务商时，优先复用这几种格式；确实不兼容时再加新的 case。
enum APIFormat: String, Codable, CaseIterable, Identifiable {
    /// OpenRouter 的 /audio/transcriptions（JSON + base64 音频）
    case openRouterTranscription
    /// OpenAI 兼容的 /audio/transcriptions（multipart 上传，Groq、OpenAI 等）
    case openAIMultipartTranscription
    /// OpenAI 兼容的 /chat/completions（用于润色）
    case chatCompletions

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openRouterTranscription: return "OpenRouter 语音转写（JSON）"
        case .openAIMultipartTranscription: return "OpenAI 兼容语音转写（multipart）"
        case .chatCompletions: return "OpenAI 兼容对话（chat/completions）"
        }
    }

    var role: ModelRole {
        switch self {
        case .openRouterTranscription, .openAIMultipartTranscription: return .transcription
        case .chatCompletions: return .polish
        }
    }

    static func formats(for role: ModelRole) -> [APIFormat] {
        allCases.filter { $0.role == role }
    }
}

/// 一条模型配置。API Key 不在这里保存，而是按 id 存进钥匙串。
struct ModelProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var format: APIFormat
    var baseURL: String
    var model: String
    /// ISO-639-1 语言代码，例如 "zh"。留空表示自动检测。
    var language: String = ""
    var temperature: Double = 0
    /// 仅对 OpenRouter 有效：只路由到"零数据保留"的服务商
    var zeroDataRetention: Bool = true
    /// 请求超时（秒）
    var timeout: Double = 15

    var role: ModelRole { format.role }

    /// OpenRouter 上的 whisper-large-v3-turbo
    static func openRouterWhisper() -> ModelProfile {
        ModelProfile(name: "OpenRouter · Whisper Large V3 Turbo",
                     format: .openRouterTranscription,
                     baseURL: "https://openrouter.ai/api/v1",
                     model: "openai/whisper-large-v3-turbo")
    }

    /// 润色模型模板：模型 ID 由用户填写
    static func openRouterPolish() -> ModelProfile {
        ModelProfile(name: "OpenRouter · 润色模型",
                     format: .chatCompletions,
                     baseURL: "https://openrouter.ai/api/v1",
                     model: "",
                     timeout: 3)
    }

    /// 通用 OpenAI 兼容语音转写模板（如 Groq：https://api.groq.com/openai/v1）
    static func openAICompatibleTranscription() -> ModelProfile {
        ModelProfile(name: "OpenAI 兼容 · 语音识别",
                     format: .openAIMultipartTranscription,
                     baseURL: "https://api.openai.com/v1",
                     model: "whisper-1",
                     zeroDataRetention: false)
    }
}

/// 插入方式
enum InsertionMode: String, Codable, CaseIterable, Identifiable {
    case live      // 实时分段上屏
    case oneShot   // 松手后一次性插入

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .live: return "实时上屏（按停顿分段）"
        case .oneShot: return "松手后一次性插入"
        }
    }
}
