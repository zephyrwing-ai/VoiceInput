import AVFoundation

/// 麦克风采集。每次录音新建一个 AVAudioEngine，所以总是使用"系统当前的默认输入设备"
///（戴着 AirPods 就是 AirPods）。
final class AudioRecorder {
    /// 音量电平 0...1（在主线程回调，约 30 次/秒）
    var onLevel: ((Float) -> Void)?
    /// 收到第一帧有效音频（用于"麦克风准备中"→ 波纹的切换）
    var onFirstAudio: (() -> Void)?
    /// 实时模式下，每切出一段语音就回调一次（在主线程）
    var onSegment: (([Float]) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                             channels: 1, interleaved: false)!
    private let queue = DispatchQueue(label: "voiceinput.audio")
    private var allSamples: [Float] = []
    private var segmenter = VoiceActivitySegmenter()
    private var receivedAudio = false
    private var lastLevelTime = Date.distantPast
    private var smoothedLevel: Float = 0
    private var segmenting = false

    /// 最长录音时长（秒）
    let maxDuration: TimeInterval = 300

    func start(segmenting: Bool) throws {
        stopEngine()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.converterUnavailable
        }

        queue.sync {
            allSamples.removeAll(keepingCapacity: true)
            segmenter = VoiceActivitySegmenter()
            receivedAudio = false
            smoothedLevel = 0
            self.segmenting = segmenting
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// 停止录音，返回整段音频和最后一段语音（实时模式用）
    func stop() -> (all: [Float], lastSegment: [Float]?, hadSpeech: Bool) {
        stopEngine()
        return queue.sync {
            let last = segmenter.finish()
            return (allSamples, last, segmenter.anySpeechDetected || last != nil)
        }
    }

    func cancel() {
        stopEngine()
        queue.sync { allSamples.removeAll() }
    }

    private func stopEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        guard !samples.isEmpty else { return }

        queue.async { [weak self] in self?.process(samples) }
    }

    private func process(_ samples: [Float]) {
        guard Double(allSamples.count) < maxDuration * 16_000 else { return }
        allSamples.append(contentsOf: samples)

        // 电平：dBFS 映射到 0...1，快升慢降
        let db = VoiceActivitySegmenter.decibels(samples)
        let target = max(0, min(1, (db + 55) / 45))
        let factor: Float = target > smoothedLevel ? 0.6 : 0.15
        smoothedLevel += (target - smoothedLevel) * factor

        if !receivedAudio, db > -90 {
            receivedAudio = true
            DispatchQueue.main.async { [weak self] in self?.onFirstAudio?() }
        }
        let now = Date()
        if now.timeIntervalSince(lastLevelTime) > 1.0 / 30 {
            lastLevelTime = now
            let level = smoothedLevel
            DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        }

        if segmenting {
            for segment in segmenter.feed(samples) {
                DispatchQueue.main.async { [weak self] in self?.onSegment?(segment) }
            }
        } else {
            _ = segmenter.feed(samples)   // 只用来判断有没有人声
        }
    }

    enum RecorderError: LocalizedError {
        case noInputDevice, converterUnavailable
        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "没有可用的麦克风"
            case .converterUnavailable: return "无法处理当前麦克风的音频格式"
            }
        }
    }
}
