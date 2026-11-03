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

    var allGranted: Bool { microphone == .authorized && accessibility }

    private init() { refresh() }

    func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        let wasGranted = accessibility
        accessibility = AXIsProcessTrusted()
        if accessibility && !wasGranted { onAccessibilityGranted?() }
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
