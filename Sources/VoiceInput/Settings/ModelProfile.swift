import Foundation

/// 模型的用途
enum ModelRole: String, Codable, CaseIterable, Identifiable {
    case transcription   // 语音识别
    case polish          // 文字润色（功能已移除，只为读取旧版本保存的配置而保留）

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .transcription: return "语音识别"
        case .polish: return "文字润色"
        }
    }
}

/// 模型配置的来源。云端使用用户填写的 Base URL 和 API Key；本地使用 App 托管的 whisper.cpp 服务。
enum ModelEndpoint: String, Codable, CaseIterable, Identifiable {
    case cloud
    case local

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .cloud: return "云端服务"
        case .local: return "本地模型"
        }
    }
}

/// 本地推理运行时的类型。当前只接入 whisper.cpp server；后续格式可以在这里扩展。
enum LocalRuntimeKind: String, Codable, Hashable {
    case whisperCppServer

    var displayName: String { "whisper.cpp" }
}

/// One model returned by a cloud provider's `/models` endpoint.
struct CloudModel: Codable, Identifiable, Hashable, Sendable {
    var modelID: String
    var name: String

    var id: String { modelID }
}

/// A provider owns the connection settings and the models it exposes.
/// Its API key lives in Keychain under the provider id.
struct CloudProvider: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var baseURL: String
    var models: [CloudModel]

    init(id: UUID = UUID(), name: String, baseURL: String, models: [CloudModel] = []) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.models = models
    }
}

/// 接口格式。由程序根据 Base URL 自动判断，用户不需要选择。
enum APIFormat: String, Codable, CaseIterable, Identifiable {
    /// OpenRouter 的 /audio/transcriptions（JSON + base64 音频，支持零数据保留路由）
    case openRouterTranscription
    /// OpenAI 兼容的 /audio/transcriptions（multipart 上传，Groq、OpenAI 等）
    case openAIMultipartTranscription
    /// OpenAI 兼容的 /chat/completions（旧版润色配置使用，功能已移除，保留用于兼容读取）
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
    var id: UUID
    var name: String
    /// 只用来区分用途（语音识别 / 润色）；语音识别实际使用的格式由 Base URL 自动判断
    var format: APIFormat
    var baseURL: String
    var model: String
    /// 云端配置连接远程接口，本地配置由 LocalModelRuntimeManager 启动本机服务。
    var endpoint: ModelEndpoint
    /// 云端模型所属的供应商；旧版本配置可能为 nil。
    var providerID: UUID?
    /// 本地模型的绝对路径；云端配置为 nil。
    var localModelPath: String?
    /// 本地配置使用的运行时；云端配置为 nil。
    var runtime: LocalRuntimeKind?

    init(id: UUID = UUID(),
         name: String,
         format: APIFormat,
         baseURL: String,
         model: String,
         endpoint: ModelEndpoint = .cloud,
         providerID: UUID? = nil,
         localModelPath: String? = nil,
         runtime: LocalRuntimeKind? = nil) {
        self.id = id
        self.name = name
        self.format = format
        self.baseURL = baseURL
        self.model = model
        self.endpoint = endpoint
        self.providerID = providerID
        self.localModelPath = localModelPath
        self.runtime = runtime
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, format, baseURL, model, endpoint, providerID, localModelPath, runtime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        format = try container.decode(APIFormat.self, forKey: .format)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        model = try container.decode(String.self, forKey: .model)
        endpoint = try container.decodeIfPresent(ModelEndpoint.self, forKey: .endpoint) ?? .cloud
        providerID = try container.decodeIfPresent(UUID.self, forKey: .providerID)
        localModelPath = try container.decodeIfPresent(String.self, forKey: .localModelPath)
        runtime = try container.decodeIfPresent(LocalRuntimeKind.self, forKey: .runtime)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(format, forKey: .format)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(model, forKey: .model)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encodeIfPresent(providerID, forKey: .providerID)
        try container.encodeIfPresent(localModelPath, forKey: .localModelPath)
        try container.encodeIfPresent(runtime, forKey: .runtime)
    }

    var role: ModelRole { format.role }
    var isLocal: Bool { endpoint == .local }
    var displayName: String { isLocal ? "本地 · \(name)" : name }
    /// 云端服务必须填写 API Key；本地服务允许空 Key。
    var requiresAPIKey: Bool { endpoint == .cloud }
    var localModelExists: Bool {
        guard let localModelPath else { return false }
        return FileManager.default.isReadableFile(atPath: localModelPath)
    }

    /// 配置是否足以发起一次识别。本地配置的文件存在性由运行时管理器检查。
    func isReady(apiKey: String) -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if isLocal {
            return localModelPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && localModelExists
        }
        return !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 实际请求时使用的接口格式
    var effectiveFormat: APIFormat {
        role == .transcription ? APIFormat.transcriptionFormat(for: baseURL) : .chatCompletions
    }

    /// OpenRouter 上的 whisper-large-v3-turbo（首次启动的默认配置）
    static func openRouterWhisper() -> ModelProfile {
        ModelProfile(name: "OpenRouter · Whisper Large V3 Turbo",
                     format: .openRouterTranscription,
                     baseURL: "https://openrouter.ai/api/v1",
                     model: "openai/whisper-large-v3-turbo",
                     endpoint: .cloud)
    }

    /// "添加"时的空白语音识别配置
    static func newTranscription() -> ModelProfile {
        ModelProfile(name: "", format: .openAIMultipartTranscription, baseURL: "", model: "", endpoint: .cloud)
    }

    /// Resolve one model from a provider catalog into the connection profile used by transcription.
    static func cloudModel(provider: CloudProvider, model: CloudModel) -> ModelProfile {
        ModelProfile(name: "\(provider.name) · \(model.name)",
                     format: .openAIMultipartTranscription,
                     baseURL: provider.baseURL,
                     model: model.modelID,
                     endpoint: .cloud,
                     providerID: provider.id)
    }

    /// 扫描到的本地模型对应的配置；baseURL 只是占位，运行时启动后会替换成实际端口。
    static func localModel(name: String, path: String, model: String) -> ModelProfile {
        ModelProfile(name: name,
                     format: .openAIMultipartTranscription,
                     baseURL: "http://127.0.0.1:0/v1",
                     model: model,
                     endpoint: .local,
                     localModelPath: path,
                     runtime: .whisperCppServer)
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
