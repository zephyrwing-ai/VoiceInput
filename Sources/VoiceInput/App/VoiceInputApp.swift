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
    private var dictation: DictationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dictation = DictationController()
        dictation.onStateChange = { [weak self] recording in self?.updateIcon(recording: recording) }
        dictation.onNeedsSettings = { [weak self] in self?.settingsWindow.show() }
        hotkey.delegate = dictation
        self.dictation = dictation

        setupMainMenu()
        installEditShortcuts()
        setupStatusItem()
        let permissions = PermissionManager.shared
        permissions.onAccessibilityGranted = { [weak self] in self?.startServices() }
        startServices()

        // 权限没给全或者没配 API Key：先打开设置窗口（显示授权进度），再主动申请权限，
        // 这样系统授权框和系统设置窗口会出现在设置窗口之上
        let store = SettingsStore.shared
        let missingKey = store.activeTranscription.map { store.apiKey(for: $0).isEmpty } ?? true
        if !permissions.allGranted || missingKey {
            settingsWindow.show()
        }
        // 一启动就主动申请麦克风和辅助功能权限，不等用户操作
        permissions.requestOnLaunch()
        if !permissions.allGranted { permissions.startPolling() }
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
        appMenu.addItem(withTitle: "退出 VoiceInput", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        let status: String
        if !AXIsProcessTrusted() {
            status = "需要授权\"辅助功能\""
        } else if !hotkey.isRunning {
            status = "快捷键未启动，请重新打开应用"
        } else {
            status = "按住 Fn + Control 说话"
        }
        let statusItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(.separator())

        let copyLast = NSMenuItem(title: "复制上一次结果", action: #selector(copyLastResult), keyEquivalent: "")
        copyLast.target = self
        copyLast.isEnabled = !(dictation?.lastResult.isEmpty ?? true)
        menu.addItem(copyLast)

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 VoiceInput", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
