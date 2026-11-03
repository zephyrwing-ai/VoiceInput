import AppKit
import AVFoundation
import ApplicationServices

@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    @Published private(set) var microphone: AVAuthorizationStatus = .notDetermined
    @Published private(set) var accessibility = false

    /// 辅助功能授权成功时回调（用于重建快捷键监听）
    var onAccessibilityGranted: (() -> Void)?
    private var pollTimer: Timer?
    /// 启动引导进行中：辅助功能授权后，如果麦克风之前被拒绝，接着打开麦克风设置页
    private var launchFlowActive = false

    var allGranted: Bool { microphone == .authorized && accessibility }

    private init() { refresh() }

    func refresh() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != microphone { microphone = mic }
        let wasGranted = accessibility
        let trusted = AXIsProcessTrusted()
        if trusted != accessibility { accessibility = trusted }
        if trusted && !wasGranted {
            onAccessibilityGranted?()
            if launchFlowActive {
                launchFlowActive = false
                if microphone == .denied || microphone == .restricted { openMicrophoneSettings() }
            }
        }
    }

    // MARK: - 启动时主动申请

    /// App 一启动就主动申请，不等用户点按钮：
    /// ① 麦克风：没问过 → 弹出系统授权框，等用户答复；
    /// ② 辅助功能：没授权 → 弹出系统提示、打开设置页并轮询，授权后自动生效；
    /// ③ 麦克风之前被拒绝过（系统不会再弹框）→ 打开麦克风设置页（辅助功能也缺时，等它授权后再打开，避免两个设置页抢窗口）。
    func requestOnLaunch() {
        refresh()
        if microphone == .notDetermined {
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in
                    self.refresh()
                    self.continueLaunchFlow()
                }
            }
        } else {
            continueLaunchFlow()
        }
    }

    private func continueLaunchFlow() {
        let micBlocked = microphone == .denied || microphone == .restricted
        if !accessibility {
            launchFlowActive = micBlocked
            requestAccessibility()
        } else if micBlocked {
            openMicrophoneSettings()
            startPolling()
        }
    }

    // MARK: - 麦克风

    /// 还没问过用户时，弹出系统授权框；用户之前拒绝过时，系统不会再弹框，只能打开系统设置
    func requestMicrophone(completion: ((Bool) -> Void)? = nil) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    self.refresh()
                    completion?(granted)
                }
            }
        case .denied, .restricted:
            openMicrophoneSettings()
            completion?(false)
        default:
            completion?(true)
        }
    }

    func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    // MARK: - 辅助功能

    /// 弹出系统提示（会把本 App 加入"辅助功能"列表），打开设置页，并开始轮询授权状态
    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        startPolling()
    }

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                self.refresh()
                if self.allGranted { timer.invalidate() }
            }
        }
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
