import AppKit
import ApplicationServices

@main
enum VoiceInputMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // 只在菜单栏常驻，不显示在 Dock
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let hotkey = HotkeyMonitor()
    private let treeEnabler = AccessibilityTreeEnabler()
    private let settingsWindow = SettingsWindowController()
    private let onboardingWindow = OnboardingWindowController()
    private var dictation: DictationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.manus.voiceinput"
        let otherInstances = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if otherInstances.isEmpty {
            LocalModelRuntimeManager.shared.reconcileOrphanServer()
        }

        let dictation = DictationController()
        dictation.onStateChange = { [weak self] recording in self?.updateIcon(recording: recording) }
        dictation.onNeedsSettings = { [weak self] in self?.settingsWindow.show() }
        hotkey.delegate = dictation
        self.dictation = dictation

        // 鼠标停在屏幕顶部中间（刘海处）时，弹出和菜单栏图标一样的菜单
        let hud = dictation.hud
        hud.menuProvider = { [weak self] in self?.hoverMenuInfo() ?? HUDMenuInfo() }
        hud.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
        hud.startHoverTrigger()

        setupMainMenu()
        installEditShortcuts()
        setupStatusItem()
        let permissions = PermissionManager.shared
        permissions.onAccessibilityGranted = { [weak self] in self?.startServices() }
        startServices()
        permissions.refresh()

        if !OnboardingState.hasBeenShown {
            // Mark first so closing or denying the onboarding never causes it to
            // reappear on a later launch.
            OnboardingState.markShown()
            onboardingWindow.openSettings = { [weak self] in self?.settingsWindow.show() }
            onboardingWindow.show()
            // Only the first-run flow actively asks the system for permissions.
            permissions.requestOnLaunch()
        } else if !permissions.allGranted {
            // Subsequent launches observe only. The user can open Settings and
            // press "去授权" explicitly; we never spawn the system prompt here.
            permissions.startPolling()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        LocalModelRuntimeManager.shared.shutdown()
    }

    /// A menu-bar-only app has no Dock window. Reopening the app from Finder or
    /// `open` should surface Settings instead of appearing to do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return true
    }

    /// 快捷键监听需要辅助功能权限；授权后再调用一次即可生效，不需要重启
    private func startServices() {
        guard AXIsProcessTrusted() else { return }
        if hotkey.start() { treeEnabler.start() }
    }

    /// ⌘V / ⌘C / ⌘X / ⌘A / ⌘Z / ⇧⌘Z：直接发给当前第一响应者，设置窗口、弹出的编辑面板里都能用
    private var editMonitor: Any?
    private func installEditShortcuts() {
        editMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command || flags == [.command, .shift],
                  let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
            let action: Selector?
            switch (key, flags == .command) {
            case ("v", true): action = #selector(NSText.paste(_:))
            case ("c", true): action = #selector(NSText.copy(_:))
            case ("x", true): action = #selector(NSText.cut(_:))
            case ("a", true): action = #selector(NSText.selectAll(_:))
            case ("z", true): action = Selector(("undo:"))
            case ("z", false): action = Selector(("redo:"))
            default: action = nil
            }
            guard let action, NSApp.sendAction(action, to: nil, from: nil) else { return event }
            return nil
        }
    }

    // MARK: - 菜单栏

    /// 菜单栏应用（LSUIElement）默认没有主菜单。而 ⌘V、⌘C 这些快捷键是通过主菜单里"编辑"菜单的
    /// 快捷键分发给输入框的，没有主菜单，设置窗口里就无法粘贴 API Key。
    /// 这个菜单不会显示出来（应用不在 Dock 也不显示菜单栏），但快捷键会生效。
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateIcon(recording: false)
    }

    private func updateIcon(recording: Bool) {
        let name = recording ? "mic.fill" : "mic"
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "VoiceInput")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let statusItem = NSMenuItem(title: currentStatus().text, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(.separator())

        let copyLast = NSMenuItem(title: "复制上一次结果", action: #selector(copyLastResult), keyEquivalent: "")
        copyLast.target = self
        copyLast.isEnabled = !(dictation?.lastResult.isEmpty ?? true)
        menu.addItem(copyLast)

        let settings = NSMenuItem(title: "设置", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// 菜单栏菜单和刘海悬停菜单共用的状态文字
    private func currentStatus() -> (text: String, ready: Bool) {
        let permissions = PermissionManager.shared
        permissions.refresh()
        if !permissions.accessibility {
            return ("需要授权\"辅助功能\"", false)
        } else if permissions.microphone != .authorized {
            return ("需要授权麦克风", false)
        } else if let profile = SettingsStore.shared.activeTranscription,
                  !profile.isReady(apiKey: SettingsStore.shared.apiKey(for: profile)) {
            return ("需要配置语音识别模型", false)
        } else if !hotkey.isRunning {
            return ("快捷键未启动，请重新打开应用", false)
        } else {
            return ("按住 Fn + Control 说话", true)
        }
    }

    private func hoverMenuInfo() -> HUDMenuInfo {
        let status = currentStatus()
        return HUDMenuInfo(status: status.text, ready: status.ready, lastResult: dictation?.lastResult ?? "")
    }

    @objc private func copyLastResult() {
        guard let text = dictation?.lastResult, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }
}
