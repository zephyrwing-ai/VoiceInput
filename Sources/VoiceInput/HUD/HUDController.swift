import AppKit
import SwiftUI

/// 不抢焦点的浮窗：显示时，用户正在输入的应用仍然保持焦点
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 浮窗不会成为 key window，VoiceInput 也不会被激活。让第一次点击直接落到按钮上，不需要先点一下"激活"
final class HUDHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class HUDController {
    let model = HUDModel()
    /// 悬停菜单的内容（状态文字、上一次结果），每次弹出前由 AppDelegate 提供最新值
    var menuProvider: (() -> HUDMenuInfo)?
    var onOpenSettings: (() -> Void)?

    private var panel: HUDPanel?
    private var autoHide: DispatchWorkItem?
    private let hoverTrigger = NotchHoverTrigger()
    private var leaveTimer: Timer?
    private var mouseLeftAt: Date?

    private let wingWidth: CGFloat = 64
    private let expandedWidth: CGFloat = 440
    private let menuWidth: CGFloat = 300
    private let expandedExtraHeight: CGFloat = 132
    /// 鼠标离开悬停菜单多久后收起：留一点余量，鼠标稍微划出去再回来不会闪
    private let menuLeaveDelay: TimeInterval = 0.35

    /// "Translating…" 的实际宽度，用来决定识别中胶囊要多宽
    private let processingLabelWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: HUDText.processingFontSize, weight: .medium)
        return ceil((HUDText.processing as NSString).size(withAttributes: [.font: font]).width)
    }()

    init() {
        model.onCopy = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        model.onClose = { [weak self] in self?.hide() }
        model.onMenuAction = { [weak self] action in self?.handleMenuAction(action) }
        hoverTrigger.onHover = { [weak self] in self?.showMenu() }
    }

    /// 开始监听"鼠标停在屏幕顶部中间"
    func startHoverTrigger() { hoverTrigger.start() }

    func show(_ phase: HUDPhase) {
        autoHide?.cancel()
        if phase != .menu { stopLeaveTracking() }
        model.phase = phase
        let panel = ensurePanel()
        configure(panel)
        layout(panel)
        panel.ignoresMouseEvents = !phase.isExpanded   // 只有卡片和菜单需要点击
        panel.orderFrontRegardless()

        if case .notice = phase {
            scheduleHide(after: 5)
        } else if phase == .menu {
            startLeaveTracking()                        // 菜单跟着鼠标走，不定时收起
        } else if phase.isExpanded {
            scheduleHide(after: 12)
        }
    }

    /// 鼠标停在刘海处时弹出菜单。只在浮层空闲时弹出，不打断录音、识别和结果卡片
    func showMenu() {
        guard model.phase == .hidden else { return }
        model.menu = menuProvider?() ?? HUDMenuInfo()
        model.copied = false
        show(.menu)
    }

    func setLevel(_ level: Float) { model.level = level }

    func hide(after delay: TimeInterval = 0) {
        if delay > 0 { scheduleHide(after: delay); return }
        autoHide?.cancel()
        stopLeaveTracking()
        model.phase = .hidden
        model.level = 0
        panel?.orderOut(nil)
    }

    private func scheduleHide(after delay: TimeInterval) {
        autoHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        autoHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - 悬停菜单

    private func handleMenuAction(_ action: HUDMenuAction) {
        switch action {
        case .copyLastResult:
            guard !model.menu.lastResult.isEmpty else { return }
            model.onCopy?(model.menu.lastResult)
            model.copied = true
        case .openSettings:
            hide()
            onOpenSettings?()
        case .quit:
            NSApp.terminate(nil)
        }
    }

    /// 菜单显示期间每 0.1 秒看一次鼠标：离开菜单和刘海超过 menuLeaveDelay 就收起
    private func startLeaveTracking() {
        stopLeaveTracking()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMenuHover() }
        }
        timer.tolerance = 0.03
        RunLoop.main.add(timer, forMode: .common)
        leaveTimer = timer
    }

    private func stopLeaveTracking() {
        leaveTimer?.invalidate()
        leaveTimer = nil
        mouseLeftAt = nil
    }

    private func checkMenuHover() {
        guard model.phase == .menu, let panel else { return stopLeaveTracking() }
        let mouse = NSEvent.mouseLocation
        // 菜单四周留 8pt 余量；没有刘海时菜单和菜单栏之间有 6pt 空隙，余量能盖住它
        let inside = NSMouseInRect(mouse, panel.frame.insetBy(dx: -8, dy: -8), false)
            || NotchGeometry.mouseInHoverZone(mouse)
        if inside {
            mouseLeftAt = nil
        } else if let leftAt = mouseLeftAt {
            if Date().timeIntervalSince(leftAt) >= menuLeaveDelay { hide() }
        } else {
            mouseLeftAt = Date()
        }
    }

    // MARK: - 窗口

    private func ensurePanel() -> HUDPanel {
        if let panel { return panel }
        let panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 32),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)  // 盖在菜单栏之上
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        // 浮层底色固定为纯黑，文字与状态色固定使用 I 的深色主题令牌
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = HUDHostingView(rootView: HUDView(model: model))
        self.panel = panel
        return panel
    }

    /// macOS 可能在全屏 Space 切换后重置窗口状态；每次显示前重新声明层级和 Space 归属。
    private func configure(_ panel: HUDPanel) {
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
    }

    /// 放在鼠标所在屏幕的顶部中间。有刘海时贴住刘海向两侧展开；没有刘海时悬浮在菜单栏下方。
    private func layout(_ panel: HUDPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NotchGeometry.screen(at: mouse) ?? NSScreen.main else { return }
        let geometry = NotchGeometry(screen: screen)
        model.hasNotch = geometry.hasNotch
        model.notchWidth = geometry.notchWidth
        model.topHeight = geometry.topHeight

        let notchWidth = geometry.notchWidth
        let collapsedWidth = notchWidth + 2 * wingWidth + 20
        let width: CGFloat
        let extraHeight: CGFloat
        switch model.phase {
        case .menu:
            width = max(menuWidth, notchWidth + 2 * wingWidth)
            extraHeight = HUDMenuMetrics.contentHeight
        case .card, .notice, .error:
            width = max(expandedWidth, notchWidth + 2 * wingWidth)
            extraHeight = expandedExtraHeight
        case .processing:
            // 有刘海：转圈在左、文字在右，右翼要放得下 "Translating…"；没有刘海：两者并排居中
            width = geometry.hasNotch
                ? notchWidth + 2 * max(wingWidth, processingLabelWidth + 16) + 20
                : max(collapsedWidth, processingLabelWidth + 12 + 6 + 2 * 16)
            extraHeight = 0
        default:
            width = collapsedWidth
            extraHeight = 0
        }
        let height = geometry.topHeight + extraHeight
        let top = geometry.hasNotch ? screen.frame.maxY : screen.visibleFrame.maxY - 6
        let frame = NSRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height)
        panel.setFrame(frame, display: true)
    }
}
