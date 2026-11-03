import AppKit
import SwiftUI

/// 不抢焦点的浮窗：显示时，用户正在输入的应用仍然保持焦点
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HUDController {
    let model = HUDModel()
    private var panel: HUDPanel?
    private var autoHide: DispatchWorkItem?

    private let wingWidth: CGFloat = 64
    private let expandedWidth: CGFloat = 440
    private let expandedExtraHeight: CGFloat = 132

    init() {
        model.onCopy = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        model.onClose = { [weak self] in self?.hide() }
    }

    func show(_ phase: HUDPhase) {
        autoHide?.cancel()
        model.phase = phase
        let panel = ensurePanel()
        layout(panel)
        panel.ignoresMouseEvents = !phase.isExpanded   // 只有卡片需要点击
        panel.orderFrontRegardless()

        if case .notice = phase {
            scheduleHide(after: 5)
        } else if phase.isExpanded {
            scheduleHide(after: 12)
        }
    }

    func setLevel(_ level: Float) { model.level = level }

    func hide(after delay: TimeInterval = 0) {
        if delay > 0 { scheduleHide(after: delay); return }
        autoHide?.cancel()
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
        // 浮层底色固定为纯黑，文字与状态色固定使用 I 的深色主题令牌
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        self.panel = panel
        return panel
    }

    /// 放在鼠标所在屏幕的顶部中间。有刘海时贴住刘海向两侧展开；没有刘海时悬浮在菜单栏下方。
    private func layout(_ panel: HUDPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }

        let hasNotch = screen.safeAreaInsets.top > 0
        var notchWidth: CGFloat = 0
        if hasNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
        }
        let topHeight = hasNotch ? screen.safeAreaInsets.top : 32
        model.hasNotch = hasNotch
        model.notchWidth = notchWidth
        model.topHeight = topHeight

        let expanded = model.phase.isExpanded
        let width = expanded ? max(expandedWidth, notchWidth + 2 * wingWidth) : notchWidth + 2 * wingWidth + 20
        let height = topHeight + (expanded ? expandedExtraHeight : 0)
        let top = hasNotch ? screen.frame.maxY : screen.visibleFrame.maxY - 6
        let frame = NSRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height)
        panel.setFrame(frame, display: true)
    }
}
