import AppKit

/// 一块屏幕顶部中间的几何信息：有没有刘海、刘海多宽、顶部多高，以及悬停感应区
struct NotchGeometry: Equatable {
    let screenFrame: NSRect
    let visibleFrame: NSRect
    let hasNotch: Bool
    let notchWidth: CGFloat
    let topHeight: CGFloat

    /// 没有刘海（外接显示器、老款 Mac）时，菜单栏正中间这么宽的一段作为感应区，和收起的胶囊差不多宽
    static let flatZoneWidth: CGFloat = 160
    /// 菜单栏自动隐藏或全屏时，保留一条容易命中的顶部感应带
    static let minimumZoneHeight: CGFloat = 16

    init(screenFrame: NSRect, visibleFrame: NSRect, hasNotch: Bool, notchWidth: CGFloat, topHeight: CGFloat) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.hasNotch = hasNotch
        self.notchWidth = notchWidth
        self.topHeight = topHeight
    }

    init(screen: NSScreen) {
        let hasNotch = screen.safeAreaInsets.top > 0
        var notchWidth: CGFloat = 0
        if hasNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
        }
        self.init(screenFrame: screen.frame, visibleFrame: screen.visibleFrame, hasNotch: hasNotch,
                  notchWidth: notchWidth, topHeight: hasNotch ? screen.safeAreaInsets.top : 32)
    }

    /// 鼠标所在的屏幕。NSMouseInRect 把屏幕上边缘算在内，鼠标顶到最上面时也能找到
    static func screen(at point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    /// 悬停感应区：有刘海时就是刘海本身；没有刘海时是菜单栏正中间的一段
    var hoverZone: NSRect {
        let width = hasNotch && notchWidth > 0 ? notchWidth : Self.flatZoneWidth
        let menuBarHeight = screenFrame.maxY - visibleFrame.maxY
        let height = hasNotch ? topHeight : max(menuBarHeight, Self.minimumZoneHeight)
        return NSRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
    }

    func hoverZoneContains(_ point: NSPoint) -> Bool {
        NSMouseInRect(point, hoverZone, false)
    }

    /// 鼠标当前是否停在它所在屏幕的顶部中间
    static func mouseInHoverZone(_ point: NSPoint = NSEvent.mouseLocation) -> Bool {
        guard let screen = screen(at: point) else { return false }
        return NotchGeometry(screen: screen).hoverZoneContains(point)
    }
}

/// 鼠标停在屏幕顶部正中间（刘海处）一小会儿就触发 onHover。
///
/// 用全局 + 本地的 mouseMoved 监听，鼠标不动时没有任何开销；监听鼠标事件不需要额外的权限。
/// 停留一小段时间才触发，避免鼠标只是经过菜单栏时误弹出。
@MainActor
final class NotchHoverTrigger {
    var onHover: (() -> Void)?
    private var monitors: [Any] = []
    private var pending: DispatchWorkItem?
    private var pollTimer: Timer?
    private let dwell: TimeInterval = 0.15

    func start() {
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            self?.mouseMoved()
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            self?.mouseMoved()
            return event
        }) {
            monitors.append(local)
        }
        // 全屏切换和菜单栏自动隐藏时，少数应用不会稳定转发 mouseMoved；
        // 低频轮询只做兜底，鼠标离开顶部时不会产生任何 UI。
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        pending?.cancel()
        pending = nil
    }

    private func mouseMoved() {
        guard NotchGeometry.mouseInHoverZone() else {
            pending?.cancel()
            pending = nil
            return
        }
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            if NotchGeometry.mouseInHoverZone() { self.onHover?() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: work)
    }
}
