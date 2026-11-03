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

final class RuleCleanerTests: XCTestCase {
    func testRemovesFillersAndRepeats() {
        XCTAssertEqual(RuleCleaner.clean("嗯，我们再进行再进行一次测试"), "我们再进行一次测试")
        XCTAssertEqual(RuleCleaner.clean("呃帮我写一个Python函数"), "帮我写一个 Python 函数")
    }

    func testKeepsStandaloneFillerReply() {
        XCTAssertEqual(RuleCleaner.clean("嗯嗯"), "嗯嗯")
    }

    func testKeepsDoubledSingleCharacters() {
        XCTAssertEqual(RuleCleaner.clean("谢谢你，看看这个"), "谢谢你，看看这个")
    }

    func testConvertsTraditionalToSimplified() {
        XCTAssertEqual(RuleCleaner.clean("這個軟體"), "这个软体")
    }

    func testDropsWhisperHallucinations() {
        XCTAssertEqual(RuleCleaner.clean("谢谢观看！"), "")
        XCTAssertEqual(RuleCleaner.clean("字幕由Amara.org社区提供"), "")
        XCTAssertEqual(RuleCleaner.clean("Thank you"), "Thank you")
    }

    func testSeparatorAndEnding() {
        XCTAssertEqual(RuleCleaner.separator(between: "明天开会", and: "记得带电脑"), "，")
        XCTAssertEqual(RuleCleaner.separator(between: "明天开会。", and: "记得带电脑"), "")
        XCTAssertEqual(RuleCleaner.separator(between: "hello", and: "world"), " ")
        XCTAssertEqual(RuleCleaner.finalizeEnding("明天开会", category: .document), "明天开会。")
        XCTAssertEqual(RuleCleaner.finalizeEnding("明天开会", category: .chat), "明天开会")
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

final class PolishDeciderTests: XCTestCase {
    private func context(_ category: AppCategory, replace: Bool = true) -> PolishContext {
        PolishContext(category: category, dictionary: [], canReplaceInsertedText: replace)
    }

    func testSkipsShortCleanText() {
        XCTAssertFalse(PolishDecider.needsModel("好的", context(.chat)))
    }

    func testCallsForCorrectionsAndLongText() {
        XCTAssertTrue(PolishDecider.needsModel("三点，不对，四点", context(.chat)))
        XCTAssertTrue(PolishDecider.needsModel("我想问一下明天的会议是在几点开始的呀", context(.general)))
    }

    func testRulesOnlyAppsAndNonReplaceableTargets() {
        XCTAssertFalse(PolishDecider.needsModel("我想问一下明天的会议是在几点开始的呀", context(.code)))
        XCTAssertFalse(PolishDecider.needsModel("我想问一下明天的会议是在几点开始的呀", context(.chat, replace: false)))
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
