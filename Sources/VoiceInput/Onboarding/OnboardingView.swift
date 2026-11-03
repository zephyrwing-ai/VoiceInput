import SwiftUI
import AppKit

/// 首次引导（设计文档 §13.3）：
/// ① 麦克风：首次启动时请求系统授权
/// ② 辅助功能：先说明用途，再打开系统设置，轮询到授权后自动回到这里
/// ③ 配置语音识别模型
/// ④ 试一试
struct OnboardingView: View {
    @ObservedObject private var permissions = PermissionManager.shared
    @ObservedObject private var store = SettingsStore.shared
    @State private var waitingForAccessibility = false
    let openSettings: () -> Void
    let close: () -> Void

    private var modelReady: Bool {
        guard let profile = store.activeTranscription else { return false }
        return profile.isReady(apiKey: store.apiKey(for: profile))
    }

    private var allReady: Bool {
        permissions.microphone == .authorized && permissions.accessibility && modelReady
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("欢迎使用 VoiceInput").textStyle(TypeScale.hero)
                Text("按住 Fn + Control 说话，松开后文字出现在光标处。")
                    .textStyle(TypeScale.body, .regular, color: Palette.textSecondary, lineHeight: 22)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, Space.xl)

            VStack(spacing: Space.sm) {
                step(number: 1, title: "允许使用麦克风", done: permissions.microphone == .authorized) {
                    if permissions.microphone == .denied || permissions.microphone == .restricted {
                        Text("麦克风权限已关闭，可以在系统设置中重新打开。")
                    }
                } action: {
                    Button("去授权") { permissions.requestMicrophone() }
                }

                step(number: 2, title: "允许\"辅助功能\"", done: permissions.accessibility) {
                    if waitingForAccessibility && !permissions.accessibility {
                        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                            TokenSpinner()
                            Text("在系统设置中打开 VoiceInput 的开关")
                        }
                        .foregroundStyle(Palette.textReading)
                        .padding(.horizontal, 10).padding(.vertical, Space.sm)
                        .background(RoundedRectangle(cornerRadius: Radius.control).fill(Palette.surfaceBubble))
                        .padding(.top, Space.xs)
                    }
                } action: {
                    Button(waitingForAccessibility ? "重新打开设置" : "去授权") {
                        waitingForAccessibility = true
                        permissions.requestAccessibility()
                    }
                }

                step(number: 3, title: "配置语音识别模型", done: modelReady) {
                    if let profile = store.activeTranscription, modelReady {
                        Text("当前使用：\(profile.name)")
                    }
                } action: {
                    Button("去配置", action: openSettings)
                }

                step(number: 4, title: "试一试", done: false, enabled: allReady) {
                    Text("在任意输入框按住 Fn + Control 说一句话")
                } action: {
                    Button("打开备忘录") { openNotes() }
                }
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                if allReady {
                    Button("完成", action: close).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                } else {
                    Button("稍后再说", action: close).buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 5 * Space.frameGap)
        .padding(.top, 6 * Space.frameGap)
        .padding(.bottom, Space.xl)
        .frame(width: 600, height: 620)
        .background(Palette.surface)
        .ignoresSafeArea()
        .tokenRoot()
        .onAppear { permissions.refresh(); permissions.startPolling() }
    }

    /// 步骤卡片：形态参考 .voice-model-card（1px 边界、14 圆角、主要表面）
    @ViewBuilder
    private func step<Content: View, Action: View>(number: Int, title: String, done: Bool, enabled: Bool = true,
                                                   @ViewBuilder content: () -> Content,
                                                   @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            ZStack {
                Circle().fill(done ? Palette.successSoft : Palette.surfaceSecondary).frame(width: 24, height: 24)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.success)
                } else {
                    Text("\(number)").font(.ui(TypeScale.code)).foregroundStyle(Palette.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).textStyle(TypeScale.subheading)
                content()
                    .textStyle(TypeScale.meta, .regular, color: Palette.textSecondary, lineHeight: 20)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.sm)
            if done {
                TagView(text: "已完成", tone: .success)
            } else {
                action().buttonStyle(SecondaryButtonStyle(size: .compact)).disabled(!enabled)
            }
        }
        .padding(.vertical, Space.md)
        .padding(.leading, Space.md)
        .padding(.trailing, 14)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(done ? Palette.bg : Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Palette.border, lineWidth: Metrics.borderWidth))
        .opacity(enabled ? 1 : 0.45)
        .tokenAnimation(value: done)
    }

    private func openNotes() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    var openSettings: () -> Void = {}

    func show() {
        if window == nil {
            let view = OnboardingView(openSettings: { [weak self] in self?.openSettings() },
                                      close: { [weak self] in self?.window?.close() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "VoiceInput 新手引导"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = PaletteNS.surface
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        bringToFront()
    }

    /// 授权完成后把引导窗口带回前台（用户此时还停留在系统设置里）
    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }
}
