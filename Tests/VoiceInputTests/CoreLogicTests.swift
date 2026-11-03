import XCTest
@testable import VoiceInput

final class ChordStateMachineTests: XCTestCase {
    func testPressBothStartsAndReleaseStops() {
        var machine = ChordStateMachine()
        XCTAssertEqual(machine.modifiersChanged(fn: true, control: false, otherModifiers: false), .none)
        XCTAssertEqual(machine.modifiersChanged(fn: true, control: true, otherModifiers: false), .start)
        XCTAssertEqual(machine.modifiersChanged(fn: false, control: true, otherModifiers: false), .stop)
        // 只剩 Control 按着时，再按 Fn 不会立刻重新开始，要先全部松开
        XCTAssertEqual(machine.modifiersChanged(fn: true, control: true, otherModifiers: false), .none)
        XCTAssertEqual(machine.modifiersChanged(fn: false, control: false, otherModifiers: false), .none)
        XCTAssertEqual(machine.modifiersChanged(fn: true, control: true, otherModifiers: false), .start)
    }

    func testOtherKeyWhileRecordingCancels() {
        var machine = ChordStateMachine()
        _ = machine.modifiersChanged(fn: true, control: true, otherModifiers: false)
        XCTAssertEqual(machine.keyDown(), .cancel)       // 例如 Fn + Control + 方向键
        XCTAssertEqual(machine.modifiersChanged(fn: false, control: false, otherModifiers: false), .none)
    }

    func testKeyBeforeChordPreventsStart() {
        var machine = ChordStateMachine()
        _ = machine.modifiersChanged(fn: false, control: true, otherModifiers: false)
        XCTAssertEqual(machine.keyDown(), .none)         // Control + C
        XCTAssertEqual(machine.modifiersChanged(fn: true, control: true, otherModifiers: false), .none)
    }

    func testExtraModifierCancels() {
        var machine = ChordStateMachine()
        _ = machine.modifiersChanged(fn: true, control: true, otherModifiers: false)
        XCTAssertEqual(machine.modifiersChanged(fn: true, control: true, otherModifiers: true), .cancel)
    }
}

/// 实时模式分段拼接：只在两个英文单词之间补空格，中文不加任何字符
final class TranscriptJoinerTests: XCTestCase {
    private func join(_ pieces: [String]) -> String {
        pieces.reduce("") { $0 + TranscriptJoiner.separator(between: $0, and: $1) + $1 }
    }

    func testChineseSegmentsAreConcatenatedAsIs() {
        XCTAssertEqual(TranscriptJoiner.separator(between: "明天开会", and: "记得带电脑"), "")
        XCTAssertEqual(TranscriptJoiner.separator(between: "明天开会。", and: "记得带电脑"), "")
        XCTAssertEqual(join(["嗯，我们再进行", "再进行一次测试"]), "嗯，我们再进行再进行一次测试")
    }

    func testMixedChineseAndEnglishAddNothing() {
        XCTAssertEqual(TranscriptJoiner.separator(between: "帮我写一个", and: "Python函数"), "")
        XCTAssertEqual(TranscriptJoiner.separator(between: "用Python", and: "写"), "")
        XCTAssertEqual(TranscriptJoiner.separator(between: "這個軟體", and: "很好用"), "")
    }

    func testEnglishWordsKeepSpace() {
        XCTAssertEqual(TranscriptJoiner.separator(between: "hello", and: "world"), " ")
        XCTAssertEqual(TranscriptJoiner.separator(between: "Hello.", and: "How are you"), " ")
        XCTAssertEqual(TranscriptJoiner.separator(between: "hello ", and: "world"), "")
        XCTAssertEqual(TranscriptJoiner.separator(between: "", and: "world"), "")
    }
}

/// 按系统首选语言统一简繁
final class ChineseScriptTests: XCTestCase {
    func testUsesFirstChineseEntryInPreferredLanguages() {
        // 界面语言是英文，但列表里有简体中文
        XCTAssertEqual(ChineseScript.preferred(from: ["en-JP", "zh-Hans-JP", "ja-JP"]), .simplified)
        XCTAssertEqual(ChineseScript.preferred(from: ["en-US", "zh-Hant-HK", "zh-Hans-CN"]), .traditional)
        XCTAssertEqual(ChineseScript.preferred(from: ["zh-Hans-CN"]), .simplified)
        XCTAssertEqual(ChineseScript.preferred(from: ["zh-Hant-TW"]), .traditional)
    }

    func testInfersScriptFromRegion() {
        XCTAssertEqual(ChineseScript.preferred(from: ["zh-TW"]), .traditional)
        XCTAssertEqual(ChineseScript.preferred(from: ["zh-HK"]), .traditional)
        XCTAssertEqual(ChineseScript.preferred(from: ["zh-CN"]), .simplified)
        XCTAssertEqual(ChineseScript.preferred(from: ["yue-Hant-HK"]), .traditional)
    }

    func testNoChineseMeansNoConversion() {
        XCTAssertNil(ChineseScript.preferred(from: ["en-US", "ja-JP"]))
        XCTAssertNil(ChineseScript.preferred(from: []))
    }

    func testConvertsOnlyCharacterForms() {
        XCTAssertEqual(ChineseScript.simplified.convert("為什麼現在他是识别到的内容"), "为什么现在他是识别到的内容")
        XCTAssertEqual(ChineseScript.simplified.convert("嗯，這個軟體，OK嗎"), "嗯，这个软体，OK吗")
        XCTAssertEqual(ChineseScript.traditional.convert("头发很长，后来我们发现了问题"), "頭髮很長，後來我們發現了問題")
        XCTAssertEqual(ChineseScript.traditional.convert("嗯嗯我用Python写的"), "嗯嗯我用Python寫的")
    }

    func testLeavesNonChineseAndJapaneseUntouched() {
        XCTAssertEqual(ChineseScript.simplified.convert("Hello world"), "Hello world")
        XCTAssertEqual(ChineseScript.simplified.convert("日本語の勉強は楽しい"), "日本語の勉強は楽しい")
        XCTAssertEqual(ChineseScript.simplified.convert("已经是简体"), "已经是简体")
    }
}

final class VoiceActivitySegmenterTests: XCTestCase {
    private func tone(ms: Int, amplitude: Float = 0.3) -> [Float] {
        (0..<(16 * ms)).map { amplitude * sin(Float($0) * 0.2) }
    }
    private func silence(ms: Int) -> [Float] { [Float](repeating: 0.0005, count: 16 * ms) }

    func testSplitsOnPause() {
        var segmenter = VoiceActivitySegmenter()
        var segments = segmenter.feed(silence(ms: 300))
        segments += segmenter.feed(tone(ms: 800))
        segments += segmenter.feed(silence(ms: 700))      // 超过 550ms 的停顿：切一段
        segments += segmenter.feed(tone(ms: 500))
        XCTAssertEqual(segments.count, 1)
        XCTAssertNotNil(segmenter.finish())              // 松手时剩下的一段
    }

    func testSilenceOnlyHasNoSpeech() {
        var segmenter = VoiceActivitySegmenter()
        XCTAssertTrue(segmenter.feed(silence(ms: 2000)).isEmpty)
        XCTAssertNil(segmenter.finish())
        XCTAssertFalse(segmenter.anySpeechDetected)
    }
}

final class WAVEncoderTests: XCTestCase {
    func testHeader() {
        let data = WAVEncoder.encode(samples: [Float](repeating: 0, count: 16_000))
        XCTAssertEqual(data.count, 44 + 32_000)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
    }
}

final class ModelCatalogTests: XCTestCase {
    /// OpenRouter 格式：带 architecture.output_modalities
    func testOpenRouterFormatUsesOutputModalities() throws {
        let json: [String: Any] = ["data": [
            ["id": "openai/whisper-large-v3-turbo", "name": "OpenAI: Whisper Large V3 Turbo",
             "architecture": ["input_modalities": ["audio"], "output_modalities": ["transcription"]]],
            ["id": "qwen/qwen3-asr-1.7b", "name": "Qwen: Qwen3 ASR 1.7B",
             "architecture": ["output_modalities": ["transcription"]]],
            ["id": "some/text-model", "name": "Text Model",
             "architecture": ["output_modalities": ["text"]]],
        ]]
        let speech = try ModelCatalog.parse(json, role: .transcription)
        XCTAssertEqual(speech.count, 3)
        XCTAssertEqual(speech.filter(\.matchesRole).map(\.id), ["openai/whisper-large-v3-turbo", "qwen/qwen3-asr-1.7b"])
        XCTAssertFalse(speech.last!.matchesRole)        // 不匹配的排在最后

        let polish = try ModelCatalog.parse(json, role: .polish)
        XCTAssertEqual(polish.first?.id, "some/text-model")
        XCTAssertTrue(polish.first!.matchesRole)
    }

    /// 普通 OpenAI 兼容格式（如 Groq）：只有 id，按名称推测是否为语音模型
    func testGenericFormatGuessesByID() throws {
        let json: [String: Any] = ["object": "list", "data": [
            ["id": "llama-3.3-70b-versatile", "object": "model"],
            ["id": "whisper-large-v3-turbo", "object": "model"],
        ]]
        let models = try ModelCatalog.parse(json, role: .transcription)
        XCTAssertEqual(models.first?.id, "whisper-large-v3-turbo")
        XCTAssertTrue(models.first!.matchesRole)
        XCTAssertEqual(models.first?.name, "whisper-large-v3-turbo")   // 没有 name 时用 id
    }

    func testMissingDataThrows() {
        XCTAssertThrowsError(try ModelCatalog.parse(["error": ["message": "bad"]], role: .polish))
    }
}

final class AutoConfigTests: XCTestCase {
    func testFormatInferredFromBaseURL() {
        XCTAssertEqual(APIFormat.transcriptionFormat(for: "https://openrouter.ai/api/v1"), .openRouterTranscription)
        XCTAssertEqual(APIFormat.transcriptionFormat(for: "https://api.groq.com/openai/v1"), .openAIMultipartTranscription)
        let profile = ModelProfile(name: "x", format: .openAIMultipartTranscription,
                                   baseURL: "https://OpenRouter.ai/api/v1", model: "m")
        XCTAssertEqual(profile.effectiveFormat, .openRouterTranscription)
    }

    func testTimeoutScalesWithAudioLength() {
        XCTAssertEqual(TranscriptionService.timeout(forWAVBytes: 44 + 32_000), 15)          // 1 秒
        XCTAssertEqual(TranscriptionService.timeout(forWAVBytes: 44 + 32_000 * 30), 40)     // 30 秒
        XCTAssertEqual(TranscriptionService.timeout(forWAVBytes: 44 + 32_000 * 600), 120)   // 上限
    }

    func testDetectsNoZDREndpointError() {
        let error = ServiceError.http(404, "No endpoints found matching your data policy (Zero data retention).")
        XCTAssertTrue(TranscriptionService.isNoZDREndpointError(error))
        XCTAssertFalse(TranscriptionService.isNoZDREndpointError(ServiceError.http(404, "Model not found")))
        XCTAssertFalse(TranscriptionService.isNoZDREndpointError(ServiceError.http(401, "data policy")))
    }

    func testOldSettingsWithRemovedFieldsStillDecode() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"旧配置","format":"openRouterTranscription",
         "baseURL":"https://openrouter.ai/api/v1","model":"openai/whisper-large-v3-turbo",
         "language":"zh","temperature":0.3,"zeroDataRetention":false,"timeout":30}
        """
        let profile = try JSONDecoder().decode(ModelProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.model, "openai/whisper-large-v3-turbo")
        XCTAssertEqual(profile.role, .transcription)
        XCTAssertEqual(profile.endpoint, .cloud)
        XCTAssertTrue(profile.requiresAPIKey)
    }
}

final class LocalModelScannerTests: XCTestCase {
    func testScansGGMLModelAndIgnoresOtherFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInput-Models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let modelURL = root.appendingPathComponent("ggml-large-v3-q5_0.bin")
        try makeGGMLFile(at: modelURL, audioState: 1280, audioLayers: 32, textLayers: 32, fileType: 6)

        let unrelatedURL = root.appendingPathComponent("not-a-model.bin")
        try Data(repeating: 0, count: 1_048_576).write(to: unrelatedURL)

        let models = await LocalModelScanner.scan(roots: [root])
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.name, "Whisper Large V3")
        XCTAssertEqual(models.first?.quantization, "q5_0")
        XCTAssertEqual(models.first?.multilingual, true)
    }

    func testLocalProfileAllowsEmptyAPIKey() throws {
        let modelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInput-Local-\(UUID().uuidString).bin")
        try Data().write(to: modelURL)
        defer { try? FileManager.default.removeItem(at: modelURL) }

        let local = ModelProfile.localModel(name: "Whisper Large V3",
                                            path: modelURL.path,
                                            model: "ggml-large-v3-q5_0")
        XCTAssertTrue(local.isLocal)
        XCTAssertFalse(local.requiresAPIKey)
        XCTAssertTrue(local.isReady(apiKey: ""))

        var missingPath = local
        missingPath.localModelPath = nil
        XCTAssertFalse(missingPath.isReady(apiKey: ""))
    }

    func testWhisperServerArgumentsExposeOpenAIEndpoint() {
        let arguments = LocalModelRuntimeManager.arguments(
            for: URL(fileURLWithPath: "/tmp/ggml-large-v3-q5_0.bin"),
            port: 18080
        )
        XCTAssertEqual(arguments, [
            "--model", "/tmp/ggml-large-v3-q5_0.bin",
            "--host", "127.0.0.1",
            "--port", "18080",
            "--inference-path", "/v1/audio/transcriptions",
            "--language", "auto",
        ])
    }

    @MainActor
    func testLocalRuntimeStartsRealModelWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["VOICEINPUT_LOCAL_MODEL_TEST"] == "1" else {
            throw XCTSkip("Set VOICEINPUT_LOCAL_MODEL_TEST=1 to run the real local-model integration test.")
        }
        let modelURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/whisper.cpp/ggml-large-v3-q5_0.bin")
        guard FileManager.default.isReadableFile(atPath: modelURL.path) else {
            throw XCTSkip("The shared large-v3 model is not installed.")
        }

        let profile = ModelProfile.localModel(name: "Whisper Large V3",
                                              path: modelURL.path,
                                              model: "ggml-large-v3-q5_0")
        defer { LocalModelRuntimeManager.shared.stop() }

        let resolved = try await LocalModelRuntimeManager.shared.prepare(profile)
        XCTAssertTrue(resolved.baseURL.hasPrefix("http://127.0.0.1:"))
        XCTAssertEqual(LocalModelRuntimeManager.shared.state, .running)

        let service = try TranscriptionService(profile: resolved, apiKey: "")
        _ = try await service.transcribe(
            wav: WAVEncoder.encode(samples: [Float](repeating: 0, count: 8_000))
        )
    }

    private func makeGGMLFile(at url: URL,
                              audioState: UInt32,
                              audioLayers: UInt32,
                              textLayers: UInt32,
                              fileType: UInt32) throws {
        var data = Data(repeating: 0, count: 1_048_576)
        func write(_ value: UInt32, at offset: Int) {
            data[offset] = UInt8(value & 0xFF)
            data[offset + 1] = UInt8((value >> 8) & 0xFF)
            data[offset + 2] = UInt8((value >> 16) & 0xFF)
            data[offset + 3] = UInt8((value >> 24) & 0xFF)
        }
        write(0x67676d6c, at: 0)
        write(51_865, at: 4)
        write(audioState, at: 12)
        write(audioLayers, at: 20)
        write(textLayers, at: 36)
        write(fileType, at: 44)
        try data.write(to: url)
    }
}

/// 刘海悬停感应区：有刘海时就是刘海本身，没有刘海时是菜单栏正中间的一段
final class NotchGeometryTests: XCTestCase {
    func testNotchZoneIsTheNotchItself() {
        // 14 英寸 MacBook Pro：1512 × 982，刘海约 185pt 宽、32pt 高
        let frame = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let geometry = NotchGeometry(screenFrame: frame, visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 950),
                                     hasNotch: true, notchWidth: 185, topHeight: 32)
        XCTAssertEqual(geometry.hoverZone, NSRect(x: 756 - 92.5, y: 950, width: 185, height: 32))
        XCTAssertTrue(geometry.hoverZoneContains(NSPoint(x: 756, y: 982)))     // 顶到最上沿
        XCTAssertTrue(geometry.hoverZoneContains(NSPoint(x: 700, y: 960)))
        XCTAssertFalse(geometry.hoverZoneContains(NSPoint(x: 600, y: 975)))    // 刘海左边的菜单栏
        XCTAssertFalse(geometry.hoverZoneContains(NSPoint(x: 756, y: 940)))    // 刘海下方
    }

    func testFlatScreenUsesMenuBarCenter() {
        // 外接显示器，位于主屏右侧，菜单栏 25pt
        let frame = NSRect(x: 1512, y: 0, width: 1920, height: 1080)
        let geometry = NotchGeometry(screenFrame: frame, visibleFrame: NSRect(x: 1512, y: 0, width: 1920, height: 1055),
                                     hasNotch: false, notchWidth: 0, topHeight: 32)
        XCTAssertEqual(geometry.hoverZone.width, NotchGeometry.flatZoneWidth)
        XCTAssertEqual(geometry.hoverZone.height, 25)
        XCTAssertTrue(geometry.hoverZoneContains(NSPoint(x: 1512 + 960, y: 1080)))
        XCTAssertFalse(geometry.hoverZoneContains(NSPoint(x: 1512 + 700, y: 1070)))
    }

    func testAutoHiddenMenuBarKeepsUsableStrip() {
        let frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let geometry = NotchGeometry(screenFrame: frame, visibleFrame: frame, hasNotch: false, notchWidth: 0, topHeight: 32)
        XCTAssertEqual(geometry.hoverZone.height, NotchGeometry.minimumZoneHeight)
        XCTAssertTrue(geometry.hoverZoneContains(NSPoint(x: 960, y: 1079)))
        XCTAssertTrue(geometry.hoverZoneContains(NSPoint(x: 960, y: 1070)))
        XCTAssertFalse(geometry.hoverZoneContains(NSPoint(x: 960, y: 1060)))
    }
}
