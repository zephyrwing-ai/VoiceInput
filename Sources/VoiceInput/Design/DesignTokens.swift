import SwiftUI
import AppKit

// 设计令牌：取值来自 I 项目 `frontend/src/styles.css` 的 `:root`（浅色）与 `:root[data-theme="dark"]`（深色），
// 语义说明见 I 项目 `docs/desktop/design/workbench/tokens.mdx`。CSS 的 px 按 1:1 换算为 pt。
// 视图只引用这里的语义名称，不直接写色值。

// MARK: - 颜色

extension NSColor {
    /// 解析 CSS 写法的十六进制颜色：#RRGGBB 或 #RRGGBBAA（sRGB）
    convenience init(cssHex: String) {
        let hex = cssHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let rgba = hex.count == 8 ? value : (value << 8) | 0xFF
        self.init(srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255,
                  green: CGFloat((rgba >> 16) & 0xFF) / 255,
                  blue: CGFloat((rgba >> 8) & 0xFF) / 255,
                  alpha: CGFloat(rgba & 0xFF) / 255)
    }

    /// 随系统明暗切换的动态色，对应 I 的 Appearance → System：持续跟随系统偏好
    static func themed(light: String, dark: String) -> NSColor {
        let lightColor = NSColor(cssHex: light)
        let darkColor = NSColor(cssHex: dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        }
    }
}

extension Color {
    static func themed(light: String, dark: String) -> Color {
        Color(nsColor: .themed(light: light, dark: dark))
    }
}

/// 窗口背景等 AppKit 场景使用的同名令牌
enum PaletteNS {
    static let bg = NSColor.themed(light: "#F8F8F8", dark: "#171717")
    static let surface = NSColor.themed(light: "#FFFFFF", dark: "#212121")
    static let shellSurface = NSColor.themed(light: "#EEEEEE", dark: "#171717")
}

enum Palette {
    // 表面
    static let bg = Color(nsColor: PaletteNS.bg)                                      // --bg
    static let surface = Color(nsColor: PaletteNS.surface)                            // --surface
    static let shellSurface = Color(nsColor: PaletteNS.shellSurface)                  // --workbench-shell-surface
    static let frameSurface = surface                                                 // --workbench-frame-surface
    static let surfaceTranslucent = Color.themed(light: "#FFFFFFF2", dark: "#212121F2") // --surface-strong-translucent
    static let surfaceHover = Color.themed(light: "#F1F1F1", dark: "#2B2B2B")         // --surface-hover
    static let surfaceSecondary = Color.themed(light: "#EEEEEE", dark: "#1D1D1D")     // --surface-secondary
    static let surfaceBubble = Color.themed(light: "#F3F3F3", dark: "#242424")        // --surface-bubble
    static let input = bg                                                             // --input
    static let backdrop = Color.themed(light: "#1717170F", dark: "#00000059")         // --backdrop

    // 墨色文字
    static let text = Color.themed(light: "#171717", dark: "#F8F8F8")                 // --text
    static let textReading = Color.themed(light: "#444444", dark: "#EEEEEE")          // --text-reading
    static let textSecondary = Color.themed(light: "#666666", dark: "#D8D8D8")        // --text-secondary
    static let textMuted = Color.themed(light: "#888888", dark: "#BABABA")            // --text-muted
    static let textFaint = Color.themed(light: "#A9A9A9", dark: "#7C7C7C")            // --text-faint

    // 线条与覆盖
    static let border = Color.themed(light: "#E4E4E4", dark: "#404040")               // --border
    static let borderStrong = Color.themed(light: "#AEAEAE", dark: "#808080")         // --border-strong
    /// --workbench-boundary：color-mix(in srgb, var(--border) 45%, transparent)
    static let boundary = border.opacity(0.45)
    static let hover = Color.themed(light: "#1717170A", dark: "#FFFFFF14")            // --hover
    static let navHover = Color.themed(light: "#17171714", dark: "#FFFFFF1F")         // --nav-hover
    static let navSelected = Color.themed(light: "#1717171F", dark: "#FFFFFF29")      // --nav-selected

    // 强调：无彩色，直接使用墨色
    static let accent = text                                                          // --accent
    static let selection = Color.themed(light: "#1717171A", dark: "#F8F8F81F")        // --selection
    static let selectionStrong = Color.themed(light: "#17171733", dark: "#F8F8F833")  // --selection-strong
    static let focusRing = Color.themed(light: "#1717173D", dark: "#F8F8F83D")        // --focus-ring
    static let focusRingStrong = Color.themed(light: "#17171759", dark: "#F8F8F859")  // --focus-ring-strong
    static let onDark = Color.themed(light: "#FFFFFF", dark: "#171717")               // --on-dark（主按钮文字）

    // 状态
    static let danger = Color.themed(light: "#C0362C", dark: "#E07A6F")               // --danger
    static let dangerSoft = Color.themed(light: "#C0362C14", dark: "#E07A6F1F")       // --danger-soft
    static let success = Color.themed(light: "#2F8A4E", dark: "#7DC495")              // --success
    static let successSoft = Color.themed(light: "#2F8A4E14", dark: "#7DC4951F")      // --success-soft
    static let warning = Color.themed(light: "#E0AF49", dark: "#E6C168")              // --warning
    static let warningSoft = Color.themed(light: "#E0AF4924", dark: "#E6C1681F")      // --warning-soft
    static let warningFaint = Color.themed(light: "#E0AF490D", dark: "#E6C1680A")     // --warning-faint
    static let warningText = Color.themed(light: "#8A5A00", dark: "#E9C46A")          // --warning-text

    // 阴影
    static let shadowSoft = Color.themed(light: "#17171712", dark: "#00000059")       // --shadow-soft
    static let shadowSearch = Color.themed(light: "#1717171F", dark: "#00000080")     // --shadow-search
    static let shadowMedium = Color.themed(light: "#17171721", dark: "#0000008C")     // --shadow-medium
    static let shadowStrong = Color.themed(light: "#17171726", dark: "#00000099")     // --shadow-strong

    /// 开关关闭时的滑块：浅色 --white-100，深色 --grey-400（I 没有开关控件，由灰阶派生）
    static let switchKnobOff = Color.themed(light: "#FFFFFF", dark: "#D8D8D8")
}

/// 刘海浮层：底色保持纯黑，与 MacBook 的物理刘海融为一体。
/// 浮层窗口固定使用深色外观（见 HUDController），因此其中的 Palette 令牌都解析为 I 的深色取值。
enum HUDPalette {
    static let background = Color.black
}

// MARK: - 字体与字号

/// 语义字号（--font-size-*），--ui-font-offset 为 0
enum TypeScale {
    static let detail: CGFloat = 9
    static let hint: CGFloat = 10
    static let caption: CGFloat = 11
    static let code: CGFloat = 12
    static let meta: CGFloat = 13
    static let body: CGFloat = 14
    static let subheading: CGFloat = 15
    static let title: CGFloat = 16
    static let heading: CGFloat = 17
    static let display: CGFloat = 18
    static let hero: CGFloat = 20
}

extension Font {
    /// 界面字体：SF Pro Text，中文自动回退到苹方。页面默认字重 500，输入与选择控件用 400。
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight)
    }

    /// 代码与模型 ID：SF Mono
    static func mono(_ size: CGFloat = TypeScale.code, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension View {
    /// 按 CSS 的字号 / 行高 / 颜色设置文字。SwiftUI 没有行高，用行距补足到目标行高。
    func textStyle(_ size: CGFloat, _ weight: Font.Weight = .medium,
                   color: Color = Palette.text, lineHeight: CGFloat? = nil) -> some View {
        font(.ui(size, weight))
            .foregroundStyle(color)
            .lineSpacing(lineHeight.map { TypeScale.lineSpacing(size: size, lineHeight: $0) } ?? 0)
    }
}

extension TypeScale {
    static func lineSpacing(size: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        let natural = font.ascender - font.descender + font.leading
        return max(0, lineHeight - natural)
    }
}

// MARK: - 间距、圆角与尺寸

/// 4px 基数：常用 4 / 8 / 12 / 16 / 24
enum Space {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    /// --workbench-frame-gap
    static let frameGap: CGFloat = 8
}

enum Radius {
    /// 普通控件
    static let control: CGFloat = 8
    /// 浮层
    static let overlay: CGFloat = 12
    /// 语音模型卡片（.voice-model-card）
    static let card: CGFloat = 14
    /// 工作台内框、设置内容面板、选择菜单（--workbench-frame-radius）
    static let frame: CGFloat = 16
    /// Composer
    static let composer: CGFloat = 20
}

enum Metrics {
    static let borderWidth: CGFloat = 1
    /// --topbar-height
    static let topbarHeight: CGFloat = 52
    /// --projects-panel-width，设置页左侧模块导航复用
    static let settingsNavWidth: CGFloat = 240
    /// 纯图标按钮热区
    static let iconButton: CGFloat = 30
    /// 共享选择控件：默认 32、紧凑 28
    static let selectHeight: CGFloat = 32
    static let selectCompactHeight: CGFloat = 28
    /// 输入框（.field input）
    static let fieldHeight: CGFloat = 38
    /// 按钮（.primary-button / .secondary-button）
    static let buttonHeight: CGFloat = 34
    /// 设置列表行（.settings-general-row）
    static let listRowHeight: CGFloat = 48
    /// 导航条目（.settings-page-nav-item）
    static let navItemHeight: CGFloat = 36
    /// 图标尺寸
    static let icon: CGFloat = 16
}

// MARK: - 动效

enum Motion {
    /// 快速状态动画
    static let fast: Double = 0.12
    /// 浮层动画
    static let overlay: Double = 0.15
    /// 标准交互动画
    static let standard: Double = 0.18
    /// 内容展开动画
    static let expand: Double = 0.2

    /// 标准缓动：cubic-bezier(.22, 1, .36, 1)，先快后慢
    static func curve(_ duration: Double = standard) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }
}

private struct TokenAnimation<Value: Equatable>: ViewModifier {
    let duration: Double
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : Motion.curve(duration), value: value)
    }
}

extension View {
    /// 使用标准缓动；系统开启“减少动态效果”时即时切换
    func tokenAnimation<Value: Equatable>(_ duration: Double = Motion.standard, value: Value) -> some View {
        modifier(TokenAnimation(duration: duration, value: value))
    }
}
