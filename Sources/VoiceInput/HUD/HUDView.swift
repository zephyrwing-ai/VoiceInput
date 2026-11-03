import SwiftUI

enum HUDPhase: Equatable {
    case hidden
    case preparing                 // 麦克风准备中（蓝牙耳机切换期间）
    case listening                 // 正在录音：显示波纹
    case processing                // 松手后：识别 / 整理中
    case card(text: String, note: String)   // 无法插入：显示文字，可复制
    case notice(String)            // 提示信息（例如授权结果）
    case error(String)

    var isExpanded: Bool {
        switch self {
        case .card, .notice, .error: return true
        default: return false
        }
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
    var onCopy: ((String) -> Void)?
    var onClose: (() -> Void)?
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
        let top: CGFloat = model.hasNotch ? 0 : radius
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: radius,
                                      bottomTrailingRadius: radius, topTrailingRadius: top)
    }

    /// 左翼：波纹 / 准备中；中间：刘海（留空）；右翼：状态图标
    private var topBar: some View {
        HStack(spacing: 0) {
            leftWing.frame(maxWidth: .infinity)
            Color.clear.frame(width: model.notchWidth)
            rightWing.frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder private var leftWing: some View {
        switch model.phase {
        case .preparing: PreparingDots()
        case .listening: Waveform(level: model.level)
        case .processing: Waveform(level: 0.05).opacity(0.5)
        case .card: Image(systemName: "doc.on.clipboard").foregroundStyle(Palette.text)
        case .notice, .error: Image(systemName: "mic").foregroundStyle(Palette.text)
        case .hidden: EmptyView()
        }
    }

    @ViewBuilder private var rightWing: some View {
        switch model.phase {
        case .preparing, .listening:
            Circle().fill(Palette.danger).frame(width: 7, height: 7)   // 正在录音的明确标识
        case .processing:
            TokenSpinner().foregroundStyle(Palette.textSecondary)
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
