import SwiftUI

enum HUDPhase: Equatable {
    case hidden
    case preparing                 // 麦克风准备中（蓝牙耳机切换期间）
    case listening                 // 正在录音：显示波纹
    case processing                // 松手后、结果出来之前：显示 "Translating…"
    case menu                      // 鼠标停在刘海处：弹出和菜单栏图标一样的快捷菜单
    case card(text: String, note: String)   // 无法插入：显示文字，可复制
    case notice(String)            // 提示信息（例如授权结果）
    case error(String)

    var isExpanded: Bool {
        switch self {
        case .card, .notice, .error, .menu: return true
        default: return false
        }
    }
}

/// 悬停面板的内容，和菜单栏图标弹出的菜单一致
struct HUDMenuInfo: Equatable {
    var status = ""
    /// false：权限或快捷键有问题，状态文字用警示色
    var ready = true
    /// 只用于"复制上一次结果"，面板上不显示原文（避免共享屏幕时被看到）
    var lastResult = ""
}

enum HUDMenuAction {
    case copyLastResult, openSettings, quit
}

/// 浮层里的固定文案
enum HUDText {
    /// 松手后、识别结果出来之前显示在刘海旁边
    static let processing = "Translating…"
    static let processingFontSize = TypeScale.code
}

/// 悬停菜单的尺寸。HUDController 按这里算出的高度设置窗口，两边必须一致
enum HUDMenuMetrics {
    static let statusHeight: CGFloat = 28
    static let rowHeight: CGFloat = 30
    static let dividerSpacing: CGFloat = 4
    /// 行的高亮底色离面板边缘 6pt，圆角 10，和面板 16 的圆角同心
    static let inset: CGFloat = 6
    static let rowRadius: CGFloat = Radius.frame - inset
    /// 行内文字再缩进 10pt，加上 inset 共 16pt，和其他卡片的内容边距一致
    static let rowPadding: CGFloat = 10

    static var contentHeight: CGFloat {
        statusHeight + 3 * rowHeight + 2 * (2 * dividerSpacing + Metrics.borderWidth) + inset
    }
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var phase: HUDPhase = .hidden
    @Published var level: Float = 0
    @Published var status: String = ""
    @Published var notchWidth: CGFloat = 0
    @Published var topHeight: CGFloat = 32
    @Published var hasNotch = false
    @Published var menu = HUDMenuInfo()
    @Published var copied = false
    var onCopy: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onMenuAction: ((HUDMenuAction) -> Void)?
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(spacing: 0) {
            topBar.frame(height: model.topHeight)
            if model.phase.isExpanded { expandedContent }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(shape.fill(HUDPalette.background))
        .clipShape(shape)
        .tokenAnimation(Motion.expand, value: model.phase)
    }

    private var shape: some Shape {
        let radius: CGFloat = model.phase.isExpanded ? Radius.frame : (model.hasNotch ? 12 : model.topHeight / 2)
        return UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius,
                                      bottomTrailingRadius: radius, topTrailingRadius: radius)
    }

    /// 左翼：波纹 / 准备中；中间：覆盖摄像头刘海的黑色区域；右翼：状态图标
    @ViewBuilder private var topBar: some View {
        if model.phase == .processing && !model.hasNotch {
            // 没有刘海时胶囊是一整块：转圈和文字并排居中
            HStack(spacing: 6) {
                TokenSpinner().foregroundStyle(Palette.textSecondary)
                processingLabel
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
        } else {
            HStack(spacing: 0) {
                leftWing.frame(maxWidth: .infinity)
                HUDPalette.background.frame(width: model.notchWidth)
                rightWing.frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 10)
        }
    }

    private var processingLabel: some View {
        Text(HUDText.processing)
            .font(.ui(HUDText.processingFontSize))
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder private var leftWing: some View {
        switch model.phase {
        case .preparing: PreparingDots()
        case .listening: Waveform(level: model.level)
        case .processing: TokenSpinner().foregroundStyle(Palette.textSecondary)
        case .card: Image(systemName: "doc.on.clipboard").foregroundStyle(Palette.text)
        case .notice, .error, .menu: Image(systemName: "mic").foregroundStyle(Palette.text)
        case .hidden: EmptyView()
        }
    }

    @ViewBuilder private var rightWing: some View {
        switch model.phase {
        case .preparing, .listening:
            Circle().fill(Palette.danger).frame(width: 7, height: 7)   // 正在录音的明确标识
        case .processing:
            processingLabel
        case .menu:
            Circle().fill(model.menu.ready ? Palette.success : Palette.warning).frame(width: 7, height: 7)
        case .card:
            Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.warning)
        case .notice:
            Image(systemName: "info.circle").foregroundStyle(Palette.textSecondary)
        case .error:
            Image(systemName: "xmark.octagon").foregroundStyle(Palette.danger)
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder private var expandedContent: some View {
        if model.phase == .menu {
            menuContent
        } else {
            VStack(alignment: .leading, spacing: 8) {
                switch model.phase {
                case .card(let text, let note):
                    Text(note).textStyle(TypeScale.code, .regular, color: Palette.textMuted)
                    ScrollView {
                        Text(text).textStyle(TypeScale.body, .regular, lineHeight: 22).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 64)
                    HStack {
                        Spacer()
                        Button("复制") { model.onCopy?(text) }.buttonStyle(PrimaryButtonStyle(size: .compact))
                        Button("关闭") { model.onClose?() }.buttonStyle(SecondaryButtonStyle(size: .compact))
                    }
                case .notice(let message), .error(let message):
                    Text(message).textStyle(TypeScale.meta, .regular, lineHeight: 20).lineLimit(3)
                    HStack { Spacer(); Button("关闭") { model.onClose?() }.buttonStyle(SecondaryButtonStyle(size: .compact)) }
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    /// 和菜单栏图标的菜单一致：状态、复制上一次结果、设置、退出
    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.menu.status)
                .textStyle(TypeScale.meta, .regular, color: model.menu.ready ? Palette.textMuted : Palette.warningText)
                .lineLimit(1)
                .padding(.horizontal, HUDMenuMetrics.rowPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: HUDMenuMetrics.statusHeight)
            menuDivider
            menuRow(model.copied ? "已复制" : "复制上一次结果",
                    icon: model.copied ? "checkmark" : "doc.on.doc", action: .copyLastResult)
                .disabled(model.menu.lastResult.isEmpty)
            menuRow("设置", icon: "gearshape", action: .openSettings)
            menuDivider
            menuRow("退出", icon: "power", action: .quit)
        }
        .padding(.horizontal, HUDMenuMetrics.inset)
        .padding(.bottom, HUDMenuMetrics.inset)
    }

    private var menuDivider: some View {
        Rectangle().fill(Palette.border)
            .frame(height: Metrics.borderWidth)
            .padding(.horizontal, HUDMenuMetrics.rowPadding)
            .padding(.vertical, HUDMenuMetrics.dividerSpacing)
    }

    private func menuRow(_ title: String, icon: String, action: HUDMenuAction) -> some View {
        Button { model.onMenuAction?(action) } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: icon).frame(width: Metrics.icon)
                Text(title)
            }
        }
        .buttonStyle(HUDMenuRowStyle())
    }
}

/// 悬停菜单的一行：整行可点，悬停时整行高亮（对应 .settings-page-nav-item 的悬停色）
struct HUDMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration) }

    private struct StyledBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false
        var body: some View {
            let active = isEnabled && (hovering || configuration.isPressed)
            configuration.label
                .font(.ui(TypeScale.meta, .regular))
                .foregroundStyle(isEnabled ? Palette.text : Palette.textFaint)
                .padding(.horizontal, HUDMenuMetrics.rowPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: HUDMenuMetrics.rowHeight)
                .background(RoundedRectangle(cornerRadius: HUDMenuMetrics.rowRadius)
                    .fill(configuration.isPressed && isEnabled ? Palette.navSelected : (active ? Palette.navHover : .clear)))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .tokenAnimation(Motion.fast, value: active)
        }
    }
}

/// 随音量变化的波纹
struct Waveform: View {
    var level: Float
    private let weights: [CGFloat] = [0.45, 0.75, 1.0, 0.75, 0.45]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(weights.indices, id: \.self) { index in
                    let wobble = 0.65 + 0.35 * sin(t * 9 + Double(index) * 1.3)
                    let height = 3 + 15 * CGFloat(level) * weights[index] * CGFloat(wobble)
                    Capsule().fill(Palette.text).frame(width: 3, height: height)
                }
            }
            .frame(height: 20)
        }
    }
}

/// 麦克风准备中：三个依次闪烁的点
struct PreparingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle().fill(Palette.text)
                        .frame(width: 4, height: 4)
                        .opacity(0.3 + 0.7 * max(0, sin(t * 5 - Double(index) * 0.8)))
                }
            }
        }
    }
}
