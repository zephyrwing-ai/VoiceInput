import Foundation

enum ServiceError: LocalizedError {
    case notConfigured(String)
    case missingAPIKey(String)
    case invalidURL(String)
    case http(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what): return "还没有配置\(what)模型，请在设置中添加"
        case .missingAPIKey(let name): return "「\(name)」缺少 API Key"
        case .invalidURL(let url): return "地址无效：\(url)"
        case .http(let code, let message): return "请求失败（\(code)）：\(message)"
        case .emptyResponse: return "服务返回了空结果"
        }
    }
}

// MARK: - 公共请求工具

enum HTTP {
    static func endpoint(_ base: String, _ path: String) throws -> URL {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + path), url.scheme?.hasPrefix("http") == true else {
            throw ServiceError.invalidURL(base)
        }
        return url
    }

    static func request(_ url: URL, apiKey: String, timeout: Double, method: String = "POST") -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if url.host?.contains("openrouter.ai") == true {
            request.setValue("VoiceInput", forHTTPHeaderField: "X-Title")
        }
        return request
    }

    /// 发请求并把非 2xx 响应转成可读的错误
    static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let message = (json["error"] as? [String: Any])?["message"] as? String
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw ServiceError.http(status, message)
        }
        return json
    }
}

// MARK: - 语音识别

struct TranscriptionService {
    let profile: ModelProfile
    let apiKey: String

    init(profile: ModelProfile, apiKey: String) throws {
        guard !apiKey.isEmpty else { throw ServiceError.missingAPIKey(profile.name) }
        self.profile = profile
        self.apiKey = apiKey
    }

    /// - Parameters:
    ///   - wav: 16kHz 单声道 WAV
    ///   - prompt: 上文或词典提示（OpenRouter 的 JSON 接口会忽略）
    func transcribe(wav: Data, prompt: String? = nil) async throws -> String {
        let url = try HTTP.endpoint(profile.baseURL, "/audio/transcriptions")
        var request = HTTP.request(url, apiKey: apiKey, timeout: profile.timeout)

        switch profile.format {
        case .openRouterTranscription:
            var body: [String: Any] = [
                "model": profile.model,
                "input_audio": ["data": wav.base64EncodedString(), "format": "wav"],
            ]
            if profile.temperature > 0 { body["temperature"] = profile.temperature }
            if !profile.language.isEmpty { body["language"] = profile.language }
            if profile.zeroDataRetention { body["provider"] = ["zdr": true] }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

        case .openAIMultipartTranscription:
            var form = MultipartForm()
            form.addFile(name: "file", filename: "audio.wav", mimeType: "audio/wav", data: wav)
            form.addField(name: "model", value: profile.model)
            form.addField(name: "response_format", value: "json")
            if profile.temperature > 0 { form.addField(name: "temperature", value: String(profile.temperature)) }
            if !profile.language.isEmpty { form.addField(name: "language", value: profile.language) }
            if let prompt, !prompt.isEmpty { form.addField(name: "prompt", value: prompt) }
            request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = form.finalize()

        case .chatCompletions:
            throw ServiceError.notConfigured("语音识别")
        }

        let json = try await HTTP.send(request)
        guard let text = json["text"] as? String else { throw ServiceError.emptyResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 文字润色

struct PolishService {
    let profile: ModelProfile
    let apiKey: String

    init(profile: ModelProfile, apiKey: String) throws {
        guard !apiKey.isEmpty else { throw ServiceError.missingAPIKey(profile.name) }
        guard !profile.model.isEmpty else { throw ServiceError.notConfigured("润色") }
        self.profile = profile
        self.apiKey = apiKey
    }

    func complete(system: String, user: String) async throws -> String {
        let url = try HTTP.endpoint(profile.baseURL, "/chat/completions")
        var request = HTTP.request(url, apiKey: apiKey, timeout: profile.timeout)
        let body: [String: Any] = [
            "model": profile.model,
            "temperature": profile.temperature,
            "max_tokens": max(64, user.count * 2),
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await HTTP.send(request)
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty else { throw ServiceError.emptyResponse }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 设置页的"测试连接"

enum ConnectionTester {
    static func test(_ profile: ModelProfile, apiKey: String) async -> Result<String, Error> {
        do {
            switch profile.role {
            case .transcription:
                // 发送 0.5 秒静音，只验证地址、Key 和模型 ID 是否可用
                let silence = [Float](repeating: 0, count: 8_000)
                let service = try TranscriptionService(profile: profile, apiKey: apiKey)
                _ = try await service.transcribe(wav: WAVEncoder.encode(samples: silence))
                return .success("连接成功")
            case .polish:
                let service = try PolishService(profile: profile, apiKey: apiKey)
                let reply = try await service.complete(system: "只回复：好", user: "测试")
                return .success("连接成功：\(reply.prefix(20))")
            }
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - multipart/form-data

struct MultipartForm {
    private let boundary = "VoiceInput-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(name: String, value: String) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }

    mutating func addFile(name: String, filename: String, mimeType: String, data: Data) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.append("\r\n")
    }

    func finalize() -> Data {
        var result = body
        result.append("--\(boundary)--\r\n")
        return result
    }
}

private extension Data {
    mutating func append(_ string: String) { append(Data(string.utf8)) }
}
