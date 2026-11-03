import SwiftUI

// 共享控件：几何与配色对应 I 项目的 .primary-button / .secondary-button / .icon-button /
// .field input / .settings-general-list 等写法。

// MARK: - 按钮

enum ButtonSize {
    /// 34pt，圆角 9，正文 14
    case regular
    /// 28pt，圆角 7，代码字号 12（.search-status-error button）
    case compact
    /// 38pt，与输入框等高
    case field

    var height: CGFloat { self == .compact ? Metrics.selectCompactHeight : (self == .field ? Metrics.fieldHeight : Metrics.buttonHeight) }
    var radius: CGFloat { self == .compact ? 7 : (self == .field ? Radius.control : 9) }
    var fontSize: CGFloat { self == .regular ? TypeScale.body : TypeScale.code }
    var padding: CGFloat { self == .compact ? Space.sm + 2 : Space.md }
}

/// 主按钮：墨色底 + 反色字
struct PrimaryButtonStyle: ButtonStyle {
    var size: ButtonSize = .regular
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration, size: size) }

    private struct StyledBody: View {
        let configuration: Configuration
        let size: ButtonSize
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .font(.ui(size.fontSize))
                .foregroundStyle(Palette.onDark)
                .padding(.horizontal, size.padding)
                .frame(minHeight: size.height)
                .background(RoundedRectangle(cornerRadius: size.radius).fill(Palette.text))
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
                .contentShape(Rectangle())
        }
    }
}

/// 次级按钮：透明底 + 1px 边界；悬停加强边界、文字与表面
struct SecondaryButtonStyle: ButtonStyle {
    var size: ButtonSize = .regular
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration, size: size) }

    private struct StyledBody: View {
        let configuration: Configuration
        let size: ButtonSize
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false
        var body: some View {
            let active = isEnabled && (hovering || configuration.isPressed)
            configuration.label
                .font(.ui(size.fontSize))
                .foregroundStyle(active ? Palette.text : Palette.textSecondary)
                .padding(.horizontal, size.padding)
                .frame(minHeight: size.height)
                .background(RoundedRectangle(cornerRadius: size.radius).fill(active ? Palette.surfaceHover : .clear))
                .overlay(RoundedRectangle(cornerRadius: size.radius)
                    .strokeBorder(active ? Palette.borderStrong : Palette.border, lineWidth: Metrics.borderWidth))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .tokenAnimation(Motion.fast, value: active)
        }
    }
}

/// 纯图标按钮：30×30 热区，圆角 8；危险操作悬停使用 danger-soft
struct IconButtonStyle: ButtonStyle {
    var danger = false
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration, danger: danger) }

    private struct StyledBody: View {
        let configuration: Configuration
        let danger: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false
        var body: some View {
            let active = isEnabled && (hovering || configuration.isPressed)
            configuration.label
                .font(.system(size: 14, weight: .regular))
                .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                .foregroundStyle(active ? (danger ? Palette.danger : Palette.text) : Palette.textSecondary)
                .background(RoundedRectangle(cornerRadius: Radius.control)
                    .fill(active ? (danger ? Palette.dangerSoft : Palette.hover) : .clear))
                .opacity(isEnabled ? 1 : 0.58)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// 设置页左侧模块导航条目
struct NavItemStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration, selected: selected) }

    private struct StyledBody: View {
        let configuration: Configuration
        let selected: Bool
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.ui(TypeScale.body, .regular))
                .foregroundStyle(selected || hovering ? Palette.text : Palette.textSecondary)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: Metrics.navItemHeight, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.control)
                    .fill(selected ? Palette.navSelected : (hovering ? Palette.navHover : .clear)))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - 输入框

/// .field：标签（说明字号 11 / 400 / 次要文字）在上，控件在下，间距 5
struct Field<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).textStyle(TypeScale.caption, .regular, color: Palette.textSecondary)
            content
        }
    }
}

/// .field input：高 38、圆角 8、输入表面；聚焦时墨色边界 + 2px 焦点环 + 主要表面
struct InputChrome: ViewModifier {
    let focused: Bool
    var height: CGFloat? = Metrics.fieldHeight
    var showsFocusHalo: Bool = true
    func body(content: Content) -> some View {
        content
            .font(.ui(TypeScale.code, .regular))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(focused ? Palette.surface : Palette.input))
            .overlay(RoundedRectangle(cornerRadius: Radius.control)
                .strokeBorder(focused && showsFocusHalo ? Palette.accent : Palette.border,
                              lineWidth: Metrics.borderWidth))
            .overlay(RoundedRectangle(cornerRadius: Radius.control + 2)
                .strokeBorder(focused && showsFocusHalo ? Palette.focusRing : .clear, lineWidth: 2)
                .padding(-2))
    }
}

struct TokenTextField: View {
    let label: String
    @Binding var text: String
    var prompt: String = ""
    var secure = false
    var showsFocusHalo = true
    @FocusState private var focused: Bool
    @State private var revealed = false

    var body: some View {
        Field(label: label) {
            HStack(spacing: Space.xs) {
                Group {
                    if secure && !revealed {
                        SecureField(label, text: $text, prompt: Text(prompt))
                    } else {
                        TextField(label, text: $text, prompt: Text(prompt))
                    }
                }
                .textFieldStyle(.plain)
                .labelsHidden()
                .focused($focused)
                if secure {
                    Button { revealed.toggle() } label: {
                        Label(revealed ? "隐藏" : "显示", systemImage: revealed ? "eye.slash" : "eye").labelStyle(.iconOnly)
                    }
                    .buttonStyle(IconButtonStyle())
                    .scaleEffect(28 / Metrics.iconButton)
                    .help(revealed ? "隐藏 API Key" : "显示 API Key")
                }
            }
            .modifier(InputChrome(focused: focused, showsFocusHalo: showsFocusHalo))
            .tokenAnimation(Motion.fast, value: focused)
        }
    }
}

// MARK: - 设置列表

/// 页面标题：--font-size-title / 24 行高 / 500
struct PageHeader: View {
    let title: String
    var body: some View {
        Text(title).textStyle(TypeScale.title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2 * Space.frameGap)
    }
}

/// 一组设置：分组名 + 列表 + 可选说明
struct SettingsGroup<Content: View, Trailing: View>: View {
    let title: String
    var hint: String?
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text(title).textStyle(TypeScale.meta, color: Palette.textSecondary)
                Spacer()
                trailing
            }
            .frame(minHeight: 28)
            content
            if let hint { HintText(hint) }
        }
    }
}

extension SettingsGroup where Trailing == EmptyView {
    init(title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, hint: hint, trailing: { EmptyView() }, content: content)
    }
}

/// .settings-general-list：输入表面、圆角 8、无外边框
struct SettingsList<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Palette.input))
            .clipShape(RoundedRectangle(cornerRadius: Radius.control))
    }
}

/// 相邻行之间的 1px 通用边界
struct RowDivider: View {
    var body: some View { Rectangle().fill(Palette.border).frame(height: Metrics.borderWidth) }
}

/// .settings-general-row：最小高 48，左右 16
struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 2 * Space.frameGap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).textStyle(TypeScale.body, .regular)
                if let detail {
                    Text(detail).textStyle(TypeScale.meta, .regular, color: Palette.textMuted, lineHeight: 18)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.lg)
            trailing.foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, Space.xs)
        .padding(.horizontal, 2 * Space.frameGap)
        .frame(minHeight: Metrics.listRowHeight)
    }
}

/// 说明文字：元信息字号 13 / 400 / 低强调
struct HintText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).textStyle(TypeScale.meta, .regular, color: Palette.textMuted, lineHeight: 20)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 胶囊标签（.voice-model-tag）
struct TagView: View {
    let text: String
    var tone: Tone = .neutral
    enum Tone { case neutral, warning, success }

    var body: some View {
        Text(text)
            .font(.ui(TypeScale.caption))
            .foregroundStyle(tone == .warning ? Palette.warningText : (tone == .success ? Palette.success : Palette.textSecondary))
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(tone == .warning ? Palette.warningSoft : (tone == .success ? Palette.successSoft : Palette.bg)))
            .overlay(Capsule().strokeBorder(tone == .neutral ? Palette.border : .clear, lineWidth: Metrics.borderWidth))
    }
}

/// 按键显示：Fn + Control
struct KeyCaps: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(keys.indices, id: \.self) { index in
                if index > 0 { Text("+").font(.ui(TypeScale.code)).foregroundStyle(Palette.textMuted) }
                Text(keys[index])
                    .font(.mono(TypeScale.code))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Palette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border, lineWidth: Metrics.borderWidth))
            }
        }
    }
}

/// 12px 加载指示（.spinner）：2px 描边，0.7s 一圈，颜色继承前景
struct TokenSpinner: View {
    var size: CGFloat = 12
    var body: some View {
        TimelineView(.animation) { context in
            let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.7) / 0.7 * 360
            Circle().trim(from: 0, to: 0.75)
                .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(angle))
        }
    }
}

/// 设置内容面板 / 工作台内框：主要表面、16 圆角、1px 分隔边、贴边阴影 0 1px 3px
struct FramePanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: Radius.frame))
            .background(RoundedRectangle(cornerRadius: Radius.frame).fill(Palette.frameSurface)
                .shadow(color: Palette.shadowSoft, radius: 1.5, y: 1))
            .overlay(RoundedRectangle(cornerRadius: Radius.frame).strokeBorder(Palette.boundary, lineWidth: Metrics.borderWidth))
    }
}

extension View {
    /// 窗口根视图的统一字体、文字色和强调色（原生控件的强调色改为墨色）
    func tokenRoot() -> some View {
        font(.ui(TypeScale.body)).foregroundStyle(Palette.text).tint(Palette.accent)
    }
}
