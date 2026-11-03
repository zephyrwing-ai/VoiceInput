import AppKit
import CoreGraphics

/// 本 App 自己合成的键盘事件（比如粘贴用的 ⌘V）会带上这个标记，监听时跳过，避免被当成"按了别的键"。
enum SyntheticEvent {
    static let marker: Int64 = 0x564F_4943   // "VOIC"
}

/// Fn + Control 组合键的判断规则（纯逻辑，便于测试）：
/// - 两个键都按下、并且期间没有按过其他键 → 开始
/// - 录音中松开任意一个 → 结束
/// - 录音中按下其他键（例如 Fn + Control + 方向键是系统的窗口平铺快捷键）→ 取消，事件照常传给系统
/// - 结束或取消后，要等两个键都松开，才能开始下一次
struct ChordStateMachine {
    enum Action: Equatable { case none, start, stop, cancel }

    private(set) var fnDown = false
    private(set) var controlDown = false
    private(set) var active = false
    private var tainted = false

    mutating func modifiersChanged(fn: Bool, control: Bool, otherModifiers: Bool) -> Action {
        fnDown = fn
        controlDown = control

        if !fn && !control {
            tainted = false
            if active { active = false; return .stop }
            return .none
        }
        if otherModifiers {
            tainted = true
            if active { active = false; return .cancel }
            return .none
        }
        if active && !(fn && control) {
            active = false
            tainted = true
            return .stop
        }
        if fn && control && !active && !tainted {
            active = true
            return .start
        }
        return .none
    }

    mutating func keyDown() -> Action {
        if active {
            active = false
            tainted = true
            return .cancel
        }
        if fnDown || controlDown { tainted = true }
        return .none
    }
}

@MainActor
protocol HotkeyMonitorDelegate: AnyObject {
    func hotkeyDidPress()
    func hotkeyDidRelease()
    func hotkeyDidCancel()
}

/// 全局监听 Fn + Control。需要"辅助功能"权限，否则 event tap 创建失败。
final class HotkeyMonitor {
    weak var delegate: HotkeyMonitorDelegate?
    private var machine = ChordStateMachine()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: hotkeyTapCallback,
                                          userInfo: refcon) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        default: break
        }
        if event.getIntegerValueField(.eventSourceUserData) == SyntheticEvent.marker { return }

        let action: ChordStateMachine.Action
        if type == .flagsChanged {
            let flags = event.flags
            let others = flags.contains(.maskShift) || flags.contains(.maskAlternate) || flags.contains(.maskCommand)
            action = machine.modifiersChanged(fn: flags.contains(.maskSecondaryFn),
                                              control: flags.contains(.maskControl),
                                              otherModifiers: others)
        } else if type == .keyDown {
            action = machine.keyDown()
        } else {
            return
        }

        // event tap 挂在主线程的 run loop 上，所以这里一定在主线程
        MainActor.assumeIsolated {
            switch action {
            case .start: delegate?.hotkeyDidPress()
            case .stop: delegate?.hotkeyDidRelease()
            case .cancel: delegate?.hotkeyDidCancel()
            case .none: break
            }
        }
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.handle(type: type, event: event)
    }
    // 不拦截任何事件：所有按键照常传给系统和当前应用
    return Unmanaged.passUnretained(event)
}
