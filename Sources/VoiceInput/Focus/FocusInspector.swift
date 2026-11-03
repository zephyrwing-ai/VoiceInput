import AppKit
import ApplicationServices

/// 按下快捷键那一刻，光标所在的输入框
struct FocusTarget {
    let element: AXUIElement?
    let pid: pid_t
    let bundleID: String?
    let appName: String
    let role: String?
    let subrole: String?
    let isEditable: Bool
    let isSecure: Bool
    let isSearchField: Bool
    let webHost: String?
    let category: AppCategory

    var description: String {
        "\(appName) [\(bundleID ?? "?")] role=\(role ?? "-") subrole=\(subrole ?? "-") editable=\(isEditable) category=\(category.rawValue)"
    }
}

enum FocusInspector {
    static func capture() -> FocusTarget {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let element = focusedElement(frontApp: frontApp)

        var pid = frontApp?.processIdentifier ?? 0
        if let element { AXUIElementGetPid(element, &pid) }
        let app = NSRunningApplication(processIdentifier: pid) ?? frontApp

        let role = element.flatMap { AX.string($0, kAXRoleAttribute) }
        let subrole = element.flatMap { AX.string($0, kAXSubroleAttribute) }
        let editableRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
        var isEditable = role.map(editableRoles.contains) ?? false
        if !isEditable, let element {
            isEditable = AX.isSettable(element, kAXValueAttribute) || AX.range(element) != nil
        }
        let webHost = element.flatMap(webAreaHost)

        return FocusTarget(element: element,
                           pid: pid,
                           bundleID: app?.bundleIdentifier,
                           appName: app?.localizedName ?? "未知应用",
                           role: role,
                           subrole: subrole,
                           isEditable: isEditable,
                           isSecure: subrole == kAXSecureTextFieldSubrole,
                           isSearchField: subrole == kAXSearchFieldSubrole || role == "AXSearchField",
                           webHost: webHost,
                           category: AppCategory.classify(bundleID: app?.bundleIdentifier, webHost: webHost))
    }

    private static func focusedElement(frontApp: NSRunningApplication?) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        if let element = AX.element(systemWide, kAXFocusedUIElementAttribute) { return element }
        // 部分应用（尤其是 Electron）通过系统级查询拿不到，再从前台应用本身查一次
        guard let frontApp else { return nil }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        return AX.element(appElement, kAXFocusedUIElementAttribute)
    }

    /// 向上查找网页区域，读取当前网址的域名（只用于判断类别，不保存）
    private static func webAreaHost(from element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let node = current else { return nil }
            if AX.string(node, kAXRoleAttribute) == "AXWebArea" {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(node, "AXURL" as CFString, &value) == .success else { return nil }
                if let url = value as? URL { return url.host }
                if let string = value as? String { return URL(string: string)?.host }
                return nil
            }
            current = AX.element(node, kAXParentAttribute)
        }
        return nil
    }
}

/// 辅助功能 API 的小工具
enum AX {
    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    /// 当前选区（光标位置 = 长度为 0 的选区），单位是 UTF-16
    static func range(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    @discardableResult
    static func setRange(_ element: AXUIElement, _ range: CFRange) -> Bool {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    static func string(_ element: AXUIElement, in range: CFRange) -> String? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         parameter, &value) == .success else { return nil }
        return value as? String
    }
}

/// 让 Electron 应用和 Chromium 浏览器暴露完整的界面结构树（设计文档 §13.4）。
/// 用户无感知；只对名单内的应用设置，每个进程一次。
final class AccessibilityTreeEnabler {
    private var handledPIDs = Set<pid_t>()
    private var observer: NSObjectProtocol?
    private let chromiumBrowserIDs: Set<String> = [
        "com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "com.brave.Browser", "com.vivaldi.Vivaldi",
    ]

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.enable(for: app)
        }
        if let front = NSWorkspace.shared.frontmostApplication { enable(for: front) }
    }

    func enable(for app: NSRunningApplication) {
        guard AXIsProcessTrusted(), !handledPIDs.contains(app.processIdentifier) else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        if isElectron(app) {
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            handledPIDs.insert(app.processIdentifier)
        } else if let id = app.bundleIdentifier, chromiumBrowserIDs.contains(id) {
            AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            handledPIDs.insert(app.processIdentifier)
        }
    }

    private func isElectron(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        let framework = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }
}
