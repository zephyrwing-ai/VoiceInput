import Foundation

/// 从服务商拉取到的一个模型
struct RemoteModel: Identifiable, Hashable {
    let id: String
    let name: String
    /// 是否适合当前用途（语音转写 / 文字润色）
    let matchesRole: Bool
}

/// "获取模型列表"：GET {base}/models
/// - OpenRouter：语音识别用 `output_modalities=transcription` 只取语音转写模型；润色取默认的文本模型列表
/// - 其他 OpenAI 兼容服务：返回全部模型，按模型 ID 推测哪些是语音模型
enum ModelCatalog {
    private static let speechKeywords = [
        "whisper", "transcribe", "stt", "asr", "speech", "scribe", "voxtral",
        "parakeet", "paraformer", "sensevoice", "nova", "chirp", "audio",
    ]

    static func fetch(baseURL: String, apiKey: String, role: ModelRole) async throws -> [RemoteModel] {
        var url = try HTTP.endpoint(baseURL, "/models")
        let isOpenRouter = url.host?.contains("openrouter.ai") == true
        if isOpenRouter, role == .transcription,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "output_modalities", value: "transcription")]
            url = components.url ?? url
        }

        let request = HTTP.request(url, apiKey: apiKey, timeout: 20, method: "GET")
        let json = try await HTTP.send(request)
        return try parse(json, role: role)
    }

    /// 解析 OpenAI 兼容的 `{"data": [{"id": ..., "name": ..., "architecture": {...}}]}`
    static func parse(_ json: [String: Any], role: ModelRole) throws -> [RemoteModel] {
        guard let items = json["data"] as? [[String: Any]] else { throw ServiceError.emptyResponse }

        let models: [RemoteModel] = items.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let name = (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            let outputs = (item["architecture"] as? [String: Any])?["output_modalities"] as? [String]
            let isSpeech: Bool
            if let outputs {
                isSpeech = outputs.contains("transcription")
            } else {
                let lower = id.lowercased()
                isSpeech = speechKeywords.contains { lower.contains($0) }
            }
            return RemoteModel(id: id, name: name, matchesRole: role == .transcription ? isSpeech : !isSpeech)
        }

        // 适合当前用途的排在前面，其余按 ID 排序
        return models.sorted {
            if $0.matchesRole != $1.matchesRole { return $0.matchesRole }
            return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
    }
}
