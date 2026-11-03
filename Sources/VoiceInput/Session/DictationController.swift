import AppKit

/// 一次"按住说"的完整流程：
/// 按下 → 记录焦点 → 录音（实时模式按停顿切段，逐段识别、逐段上屏）
/// 松手 → 识别最后一段 → 恢复剪贴板
///
/// 识别模型返回什么就写入什么：不删语气词、不去重、不补标点、不调用润色模型，
/// 也不给识别模型附加上文或词典提示。唯一的处理是按系统首选语言统一简繁字形（见 ChineseScript）。
@MainActor
final class DictationController: HotkeyMonitorDelegate {
    private let settings = SettingsStore.shared
    private let permissions = PermissionManager.shared
    private let recorder = AudioRecorder()
    private let inserter = TextInserter()
    let hud = HUDController()

    /// 最近一次的结果，只保存在内存里（菜单"复制上一次结果"用），退出即清空
    private(set) var lastResult = ""
    var onStateChange: ((Bool) -> Void)?
    var onNeedsSettings: (() -> Void)?

    private final class Session {
        let target: FocusTarget
        let mode: InsertionMode
        /// 按下时从系统首选语言读出的中文书写形式；nil 表示系统语言里没有中文，不转换
        let script: ChineseScript?
        let startedAt = Date()
        var receivedAudio = false
        var pipeline: Task<Void, Never>?
        var allText = ""          // 本次识别出的全部文字（模型原文，按段拼接）
        var pendingText = ""      // 没能写进输入框的部分
        var liveStopped = false   // 焦点变了或写入失败：停止实时上屏
        var lastError: Error?
        init(target: FocusTarget, mode: InsertionMode, script: ChineseScript?) {
            self.target = target
            self.mode = mode
            self.script = script
        }
    }

    private enum State { case idle, recording(Session), finishing }
    private var state: State = .idle

    /// 按住不到这个时长就当作误触，直接丢弃
    private let minimumHold: TimeInterval = 0.3
    /// 松手后多录一小段，避免切掉最后一个字
    private let releaseTail: UInt64 = 200_000_000

    init() {
        recorder.onLevel = { [weak self] level in self?.hud.setLevel(level) }
        recorder.onFirstAudio = { [weak self] in
            guard let self, case .recording(let session) = self.state else { return }
            session.receivedAudio = true
            if self.hud.model.phase == .preparing { self.hud.show(.listening) }
        }
        recorder.onSegment = { [weak self] samples in self?.enqueueLiveSegment(samples) }
    }

    // MARK: - HotkeyMonitorDelegate

    func hotkeyDidPress() {
        guard case .idle = state else { return }   // 上一次还在收尾，忽略
        permissions.refresh()
        guard ensureMicrophone() else { return }
        guard let profile = settings.activeTranscription,
              profile.isReady(apiKey: settings.apiKey(for: profile)) else {
            return showSetupError("还没有配置语音识别模型，请在设置中添加")
        }

        let target = FocusInspector.capture()
        NSLog("[VoiceInput] 目标：\(target.description)")
        if target.isSecure {
            hud.show(.error("密码框中不能使用语音输入"))
            return
        }
        // 找不到输入框、或者是搜索框（每写一个字都会触发搜索）：改为松手后一次性处理
        let canLive = target.element != nil && target.isEditable && !target.isSearchField
        let mode: InsertionMode = canLive ? settings.insertionMode : .oneShot

        let script = ChineseScript.preferred()
        NSLog("[VoiceInput] 系统语言：\(Locale.preferredLanguages.joined(separator: ", "))，中文输出：\(script?.displayName ?? "保持原样")")
        let session = Session(target: target, mode: mode, script: script)
        inserter.beginSession()
        do {
            try recorder.start(segmenting: mode == .live)
        } catch {
            hud.show(.error(error.localizedDescription))
            return
        }
        state = .recording(session)
        onStateChange?(true)
        if settings.playSounds { NSSound(named: "Tink")?.play() }
        hud.show(.listening)

        // 300ms 内还没有收到音频（通常是蓝牙耳机在切换），显示"麦克风准备中"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, case .recording(let current) = self.state, current === session,
                  !session.receivedAudio else { return }
            self.hud.show(.preparing)
        }
    }

    func hotkeyDidRelease() {
        guard case .recording(let session) = state else { return }
        if Date().timeIntervalSince(session.startedAt) < minimumHold {
            return discard(session)
        }
        state = .finishing
        hud.show(.processing)

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.releaseTail ?? 0)
            guard let self else { return }
            let result = self.recorder.stop()
            guard result.hadSpeech else {
                self.hud.hide()
                return self.complete()
            }
            if session.mode == .live {
                if let last = result.lastSegment { self.enqueue(last, for: session) }
                await session.pipeline?.value
                await self.finishLive(session)
            } else {
                await self.finishOneShot(session, samples: result.all)
            }
            self.complete()
        }
    }

    func hotkeyDidCancel() {
        guard case .recording(let session) = state else { return }
        discard(session)
    }

    // MARK: - 麦克风权限：启动时已主动申请，这里兜底（用户关掉了弹框或之后在系统设置里关闭）

    /// 已授权返回 true。否则就地处理，返回 false，本次按键不录音。
    private func ensureMicrophone() -> Bool {
        switch permissions.microphone {
        case .authorized:
            return true
        case .notDetermined:
            // 弹出系统授权框；用户点"允许"后，再按一次就能说话
            hud.show(.notice("请在弹窗中允许 VoiceInput 使用麦克风"))
            permissions.requestMicrophone { [weak self] granted in
                self?.hud.show(granted
                    ? .notice("麦克风已开启。再按住 Fn + Control 就可以说话了")
                    : .error("没有麦克风权限，无法语音输入。可以在系统设置 → 隐私与安全性 → 麦克风中打开"))
            }
            return false
        default:
            // 用户之前拒绝过：系统不会再弹框，只能去系统设置里打开
            hud.show(.error("麦克风权限已关闭。已为你打开系统设置，请打开 VoiceInput 的开关"))
            permissions.openMicrophoneSettings()
            return false
        }
    }

    // MARK: - 实时模式

    private func enqueueLiveSegment(_ samples: [Float]) {
        guard case .recording(let session) = state, session.mode == .live else { return }
        enqueue(samples, for: session)
    }

    /// 各段按顺序识别、按顺序上屏
    private func enqueue(_ samples: [Float], for session: Session) {
        let wav = WAVEncoder.encode(samples: samples)
        let previous = session.pipeline
        session.pipeline = Task { [weak self] in
            await previous?.value
            await self?.processLiveSegment(wav, session: session)
        }
    }

    private func processLiveSegment(_ wav: Data, session: Session) async {
        guard let text = await transcribe(wav, session: session), !text.isEmpty else { return }

        let piece = TranscriptJoiner.separator(between: session.allText, and: text) + text
        session.allText += piece

        if !session.liveStopped, inserter.isStillFocused(session.target),
           inserter.insert(piece, into: session.target) != nil {
            return
        }
        session.liveStopped = true
        session.pendingText += piece
    }

    private func finishLive(_ session: Session) async {
        guard !session.allText.isEmpty else { return showFailure(session) }

        if session.liveStopped {
            inserter.endSession()
            lastResult = session.allText
            return showCard(session.pendingText, note: "输入框已切换，后面的内容没有写入，已复制到剪贴板")
        }

        // 每一段在识别完成时已经原样写入，松手后不再改动输入框里的文字
        lastResult = inserter.insertedText
        inserter.endSession()
        hud.hide()
    }

    // MARK: - 一次性模式

    private func finishOneShot(_ session: Session, samples: [Float]) async {
        guard let text = await transcribe(WAVEncoder.encode(samples: samples), session: session), !text.isEmpty else {
            return showFailure(session)
        }
        lastResult = text

        let target = session.target
        if target.element != nil, target.isEditable, inserter.isStillFocused(target),
           inserter.insert(text, into: target) != nil {
            inserter.endSession()
            hud.hide()
        } else {
            showCard(text, note: "没有找到可以输入的位置，已复制到剪贴板，按 ⌘V 粘贴")
        }
    }

    // MARK: - 模型调用

    /// 只把录音发给识别模型，返回模型的识别结果（只按系统语言统一简繁字形）
    private func transcribe(_ wav: Data, session: Session) async -> String? {
        guard let profile = settings.activeTranscription else { return nil }
        do {
            let resolved = try await LocalModelRuntimeManager.shared.prepare(profile)
            let service = try TranscriptionService(profile: resolved, apiKey: settings.apiKey(for: profile))
            let raw = try await service.transcribe(wav: wav)
            LocalModelRuntimeManager.shared.markUsed()
            return session.script?.convert(raw) ?? raw
        } catch {
            NSLog("[VoiceInput] 识别失败：\(error.localizedDescription)")
            session.lastError = error
            return nil
        }
    }

    // MARK: - 收尾

    private func showCard(_ text: String, note: String) {
        inserter.copyForManualPaste(text)
        hud.show(.card(text: text, note: note))
    }

    private func showFailure(_ session: Session) {
        inserter.endSession()
        if let error = session.lastError {
            hud.show(.error("识别失败：\(error.localizedDescription)"))
        } else {
            hud.hide()
        }
    }

    private func showSetupError(_ message: String) {
        hud.show(.error(message))
        onNeedsSettings?()
    }

    private func discard(_ session: Session) {
        recorder.cancel()
        session.pipeline?.cancel()
        inserter.endSession()
        hud.hide()
        complete()
    }

    private func complete() {
        state = .idle
        onStateChange?(false)
    }
}
