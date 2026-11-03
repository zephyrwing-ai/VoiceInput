import Foundation

/// 把 16kHz 单声道 Float 采样编码成 16-bit PCM WAV
enum WAVEncoder {
    static func encode(samples: [Float], sampleRate: Int = 16_000) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1))                       // PCM
        append(UInt16(1))                       // 单声道
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))          // byte rate
        append(UInt16(2))                       // block align
        append(UInt16(16))                      // bits per sample
        data.append(contentsOf: Array("data".utf8)); append(UInt32(dataSize))
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append(Int16(clamped * Float(Int16.max)))
        }
        return data
    }
}

/// 基于能量的简易语音活动检测 + 分段。
/// 用于"实时上屏"：云端 Whisper 不支持流式，所以按停顿把音频切成小段，逐段识别、逐段上屏。
struct VoiceActivitySegmenter {
    struct Config {
        var sampleRate = 16_000
        var frameMs = 20
        /// 说话后静音持续多久就切一段
        var pauseMs = 550
        /// 单段最长时长，超过就强制切段
        var maxSegmentMs = 9_000
        /// 段首额外保留的前导音频，避免切掉第一个字
        var preRollMs = 200
        /// 比环境噪声高多少分贝算作人声
        var speechMarginDB: Float = 10
        /// 人声的绝对下限（dBFS）
        var minSpeechDB: Float = -48
    }

    let config: Config
    private var frameSize: Int { config.sampleRate * config.frameMs / 1000 }
    private var pending: [Float] = []           // 不足一帧的余量
    private var current: [Float] = []           // 当前段的音频
    private var preRoll: [Float] = []
    private var noiseFloorDB: Float = -60
    private var calibratedFrames = 0
    private var hasSpeech = false
    private var silentFrames = 0
    private(set) var anySpeechDetected = false

    init(config: Config = Config()) { self.config = config }

    /// 送入新的采样，返回已经切好的完整语音段
    mutating func feed(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        var segments: [[Float]] = []
        while pending.count >= frameSize {
            let frame = Array(pending.prefix(frameSize))
            pending.removeFirst(frameSize)
            if let segment = process(frame) { segments.append(segment) }
        }
        return segments
    }

    /// 录音结束：返回最后一段（如果包含人声）
    mutating func finish() -> [Float]? {
        current.append(contentsOf: pending)
        pending.removeAll()
        defer { reset() }
        return hasSpeech ? current : nil
    }

    static func decibels(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return -100 }
        let meanSquare = frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)
        return 10 * log10(max(meanSquare, 1e-10))
    }

    private mutating func process(_ frame: [Float]) -> [Float]? {
        let db = Self.decibels(frame)
        // 前 200ms 用来估计环境噪声
        if calibratedFrames < 10 {
            noiseFloorDB = calibratedFrames == 0 ? db : (noiseFloorDB * Float(calibratedFrames) + db) / Float(calibratedFrames + 1)
            calibratedFrames += 1
        }
        let isSpeech = db > max(noiseFloorDB + config.speechMarginDB, config.minSpeechDB)

        if !hasSpeech {
            // 还没开始说话：只维护前导缓冲
            preRoll.append(contentsOf: frame)
            let maxPreRoll = config.sampleRate * config.preRollMs / 1000
            if preRoll.count > maxPreRoll { preRoll.removeFirst(preRoll.count - maxPreRoll) }
            if isSpeech {
                hasSpeech = true
                anySpeechDetected = true
                current = preRoll
                preRoll.removeAll()
                silentFrames = 0
            }
            return nil
        }

        current.append(contentsOf: frame)
        silentFrames = isSpeech ? 0 : silentFrames + 1
        let pauseFrames = config.pauseMs / config.frameMs
        let maxSamples = config.sampleRate * config.maxSegmentMs / 1000
        if silentFrames >= pauseFrames || current.count >= maxSamples {
            let segment = current
            current.removeAll()
            hasSpeech = false
            silentFrames = 0
            return segment
        }
        return nil
    }

    private mutating func reset() {
        current.removeAll()
        preRoll.removeAll()
        hasSpeech = false
        silentFrames = 0
    }
}
