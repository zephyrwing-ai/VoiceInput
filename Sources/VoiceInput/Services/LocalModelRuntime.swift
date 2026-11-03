import Combine
import Darwin
import Foundation

enum LocalModelRuntimeState: Equatable {
    case stopped
    case starting
    case running
    case failed(String)

    var isRunning: Bool { self == .running }
    var isStarting: Bool { self == .starting }

    var label: String {
        switch self {
        case .stopped: return "未启动"
        case .starting: return "正在加载模型…"
        case .running: return "运行中"
        case .failed: return "运行失败"
        }
    }
}

enum LocalModelRuntimeError: LocalizedError {
    case serverMissing
    case modelMissing(String)
    case startFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .serverMissing:
            return "没有找到 whisper-server 运行组件，请重新打包 VoiceInput"
        case .modelMissing(let path):
            return "本地模型文件不存在或不可读：\(path)"
        case .startFailed(let message):
            return "本地模型服务启动失败：\(message)"
        case .timeout:
            return "本地模型加载超时，请确认模型格式和运行组件版本"
        }
    }
}

/// Owns the optional local whisper.cpp server process. A server is started on demand,
/// reused across dictation sessions, and stopped after an idle period or app termination.
@MainActor
final class LocalModelRuntimeManager: ObservableObject {
    static let shared = LocalModelRuntimeManager()

    @Published private(set) var state: LocalModelRuntimeState = .stopped
    @Published private(set) var runningModelPath: String?
    @Published private(set) var endpoint: URL?

    /// Keep the loaded model alive for a few minutes so a second dictation does not reload 1 GB.
    var idleTimeout: TimeInterval = 300

    private var process: Process?
    private var pipe: Pipe?
    private var startupTask: Task<URL, Error>?
    private var idleTask: Task<Void, Never>?
    private var logBuffer = ""
    private var lastUsedAt: Date?
    private var stateFileURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let directory = applicationSupport.appendingPathComponent("VoiceInput", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("whisper-server.json")
    }

    private struct PersistedServer: Codable {
        let pid: Int32
        let port: Int
        let modelPath: String
        let executablePath: String
    }

    private init() {}

    var serverURL: URL? {
        if let override = ProcessInfo.processInfo.environment["VOICEINPUT_WHISPER_SERVER"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("whisper-server"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/whisper-server"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Support/whisper-server"),
        ].compactMap { $0 }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    var isServerAvailable: Bool { serverURL != nil }

    /// A previous app process can leave its child server alive after a crash or rebuild.
    /// Kill only the recorded process when it still points at our bundled executable.
    func reconcileOrphanServer() {
        guard let data = try? Data(contentsOf: stateFileURL),
              let saved = try? JSONDecoder().decode(PersistedServer.self, from: data) else {
            return
        }
        defer { try? FileManager.default.removeItem(at: stateFileURL) }
        guard kill(saved.pid, 0) == 0 else { return }
        guard let executable = executablePath(for: saved.pid),
              executable == saved.executablePath else {
            return
        }
        _ = kill(saved.pid, SIGTERM)
    }

    /// Resolve a profile into the concrete base URL used for this request.
    func prepare(_ profile: ModelProfile) async throws -> ModelProfile {
        guard profile.isLocal else { return profile }
        guard let path = profile.localModelPath else {
            throw LocalModelRuntimeError.modelMissing("<empty>")
        }
        let modelURL = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: modelURL.path) else {
            throw LocalModelRuntimeError.modelMissing(path)
        }

        let serverEndpoint = try await ensureRunning(modelURL: modelURL)
        var resolved = profile
        resolved.baseURL = serverEndpoint.absoluteString
        return resolved
    }

    /// Return the endpoint for a model, starting the server if necessary.
    func ensureRunning(modelURL: URL) async throws -> URL {
        let path = modelURL.standardizedFileURL.path
        if runningModelPath == path, state.isRunning, let endpoint {
            touch()
            return endpoint
        }
        if runningModelPath == path, state.isStarting, let startupTask {
            return try await startupTask.value
        }
        if process != nil || state.isStarting {
            stop()
        }

        guard let executable = serverURL else {
            state = .failed(LocalModelRuntimeError.serverMissing.localizedDescription)
            throw LocalModelRuntimeError.serverMissing
        }
        guard let port = Self.freePort() else {
            state = .failed("没有可用的本地端口")
            throw LocalModelRuntimeError.startFailed("没有可用的本地端口")
        }

        state = .starting
        runningModelPath = path
        endpoint = nil
        logBuffer = ""
        let task = Task { [weak self] in
            guard let self else { throw LocalModelRuntimeError.startFailed("运行时已释放") }
            return try await self.startAndWait(executable: executable, modelURL: modelURL, port: port)
        }
        startupTask = task

        do {
            let startedEndpoint = try await task.value
            startupTask = nil
            endpoint = startedEndpoint
            state = .running
            lastUsedAt = Date()
            scheduleIdleStop()
            return startedEndpoint
        } catch {
            startupTask = nil
            terminateProcess()
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            runningModelPath = nil
            endpoint = nil
            throw error
        }
    }

    /// Called after a successful transcription to reset the idle timer.
    func markUsed() {
        touch()
    }

    func stop() {
        idleTask?.cancel()
        idleTask = nil
        startupTask?.cancel()
        startupTask = nil
        terminateProcess()
        state = .stopped
        runningModelPath = nil
        endpoint = nil
        lastUsedAt = nil
    }

    func shutdown() {
        stop()
    }

    private func touch() {
        lastUsedAt = Date()
        scheduleIdleStop()
    }

    private func scheduleIdleStop() {
        idleTask?.cancel()
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.state.isRunning else { return }
            let last = self.lastUsedAt ?? .distantPast
            if Date().timeIntervalSince(last) >= timeout {
                self.stop()
            }
        }
    }

    private func startAndWait(executable: URL, modelURL: URL, port: Int) async throws -> URL {
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(for: modelURL, port: port)
        process.currentDirectoryURL = executable.deletingLastPathComponent()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.appendLog(text) }
        }
        process.terminationHandler = { [weak self, weak process] terminated in
            Task { @MainActor in
                guard let self, self.process === process else { return }
                try? FileManager.default.removeItem(at: self.stateFileURL)
                if self.state.isRunning {
                    self.state = .failed("本地模型服务已退出（\(terminated.terminationStatus)）")
                    self.runningModelPath = nil
                    self.endpoint = nil
                }
            }
        }

        self.process = process
        self.pipe = pipe
        do {
            try process.run()
            persistServerState(
                pid: process.processIdentifier,
                port: port,
                modelPath: modelURL.path,
                executablePath: executable.path
            )
        } catch {
            terminateProcess()
            throw LocalModelRuntimeError.startFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if !process.isRunning {
                throw LocalModelRuntimeError.startFailed(lastLog)
            }
            if await isHealthy(port: port) {
                return URL(string: "http://127.0.0.1:\(port)/v1")!
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw LocalModelRuntimeError.timeout
    }

    nonisolated static func arguments(for modelURL: URL, port: Int) -> [String] {
        [
            "--model", modelURL.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            // v1.8.3 的默认转写路径是 /inference；改成这个路径后直接兼容 OpenAI 音频接口。
            "--inference-path", "/v1/audio/transcriptions",
            "--language", "auto",
        ]
    }

    private func isHealthy(port: Int) async -> Bool {
        for path in ["/health", "/v1/models"] {
            guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode) {
                return true
            }
        }
        return false
    }

    private func terminateProcess() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        pipe = nil
        try? FileManager.default.removeItem(at: stateFileURL)
    }

    private func persistServerState(pid: Int32, port: Int, modelPath: String, executablePath: String) {
        let state = PersistedServer(
            pid: pid,
            port: port,
            modelPath: modelPath,
            executablePath: executablePath
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateFileURL, options: .atomic)
    }

    private func executablePath(for pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = buffer.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private func appendLog(_ text: String) {
        logBuffer += text
        if logBuffer.count > 4_000 {
            logBuffer = String(logBuffer.suffix(4_000))
        }
    }

    private var lastLog: String {
        let trimmed = logBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "进程已退出" : String(trimmed.suffix(1_000))
    }

    private static func freePort() -> Int? {
        for port in 18080...18120 {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result == 0 { return port }
        }
        return nil
    }
}
