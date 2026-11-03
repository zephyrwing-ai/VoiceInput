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

/// 接口格式。由程序根据 Base URL 自动判断，用户不需要选择。
enum APIFormat: String, Codable, CaseIterable, Identifiable {
    /// OpenRouter 的 /audio/transcriptions（JSON + base64 音频，支持零数据保留路由）
    case openRouterTranscription
    /// OpenAI 兼容的 /audio/transcriptions（multipart 上传，Groq、OpenAI 等）
    case openAIMultipartTranscription
    /// OpenAI 兼容的 /chat/completions（用于润色）
    case chatCompletions

    var id: String { rawValue }

    var role: ModelRole {
        switch self {
        case .openRouterTranscription, .openAIMultipartTranscription: return .transcription
        case .chatCompletions: return .polish
        }
    }

    /// 语音识别：OpenRouter 用 JSON 接口，其他服务一律用 OpenAI 兼容的 multipart 接口
    static func transcriptionFormat(for baseURL: String) -> APIFormat {
        baseURL.lowercased().contains("openrouter.ai") ? .openRouterTranscription : .openAIMultipartTranscription
    }
}

/// 一条模型配置：用户只填写名称、Base URL、API Key 和模型 ID。
/// API Key 不在这里保存，而是按 id 存进钥匙串；其他参数（接口格式、超时、语言、零数据保留等）由程序自动处理。
struct ModelProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// 只用来区分用途（语音识别 / 润色）；语音识别实际使用的格式由 Base URL 自动判断
    var format: APIFormat
    var baseURL: String
    var model: String

    var role: ModelRole { format.role }

    /// 实际请求时使用的接口格式
    var effectiveFormat: APIFormat {
        role == .transcription ? APIFormat.transcriptionFormat(for: baseURL) : .chatCompletions
    }

    /// OpenRouter 上的 whisper-large-v3-turbo（首次启动的默认配置）
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
                     model: "")
    }

    /// "添加"时的空白语音识别配置
    static func newTranscription() -> ModelProfile {
        ModelProfile(name: "", format: .openAIMultipartTranscription, baseURL: "", model: "")
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
