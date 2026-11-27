import PaperReaderKit
import SwiftUI

enum QuickStartStep: Int, CaseIterable {
    case importPaper, modelSettings, bilingual, annotation, noteHover, assistant

    var usesSample: Bool {
        switch self {
        case .bilingual, .annotation, .noteHover, .assistant: true
        default: false
        }
    }

    var requiresAnchor: Bool {
        self != .noteHover
    }

    var chapter: String {
        switch self {
        case .importPaper, .modelSettings: "开始使用"
        case .bilingual, .annotation, .noteHover, .assistant: "阅读与笔记"
        }
    }

    var title: String {
        switch self {
        case .importPaper: "导入与查找论文"
        case .modelSettings: "连接模型服务"
        case .bilingual: "原版与双语重排"
        case .annotation: "如何记录笔记"
        case .noteHover: "笔记悬停状态展示"
        case .assistant: "AI 精读、导出与回顾"
        }
    }

    var instruction: String {
        switch self {
        case .importPaper:
            #if os(macOS)
                "拖入 PDF 或点「导入 PDF」添加本地论文，点书架加号格可在线查找；指针停在封面上按住空格即可预览摘要。也可以直接试读内置两页示例《\(DemoPaper.title)》。"
            #else
                "点「导入 PDF」添加本地论文，点书架加号格可在线查找；长按封面即可预览摘要。也可以直接试读内置两页示例《\(DemoPaper.title)》。"
            #endif
        case .modelSettings:
            "点齿轮打开「设置 → 模型服务」，选择服务商并填入 API 密钥。双语重排、论文助读和书库助理共用此配置；离线阅读和写笔记可直接跳过。"
        case .bilingual:
            "顶栏可随时切换「原版」与「双语重排」。本地 PDF 进入重排后按段排版、优先翻译当前页；未配置密钥时也可先读英文段落并记录页边笔记。"
        case .annotation:
            "拖选任意句子会自动弹出批注菜单，可直接高亮、下划线或点「添加笔记」；单击已有标注也能写笔记。编辑器支持实时 Markdown、LaTeX 公式和跨论文笔记引用，修改自动保存。"
        case .noteHover:
            "收起侧栏进入双语重排后，带笔记的原句下会出现手绘波浪线，页边排布摘要卡。鼠标悬停在波浪线文字或页边卡片上，原句轻浮、虚线相连并展开完整预览；点击卡片即可编辑。"
        case .assistant:
            "点「AI 精读」生成分色批注与文末总结，也可就选文提问；在「笔记」页一键整理到 Obsidian。回到书库可通过「阅读笔记」「阅读日历」与「书库助理」回顾全部研究线索。"
        }
    }
}

extension EnvironmentValues {
    @Entry var quickStartStep: QuickStartStep? = nil
}

struct QuickStartAnchors: PreferenceKey {
    static var defaultValue: [QuickStartStep: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [QuickStartStep: Anchor<CGRect>], nextValue: () -> [QuickStartStep: Anchor<CGRect>])
    {
        value.merge(nextValue()) { _, next in next }
    }
}

private struct QuickStartAnchorReporter: View {
    let step: QuickStartStep?
    @Environment(\.quickStartStep) private var activeStep

    var body: some View {
        if let step, activeStep == step {
            Color.clear.anchorPreference(key: QuickStartAnchors.self, value: .bounds) { [step: $0] }
        }
    }
}

extension View {
    /// Emits a preference anchor only while onboarding is active on this exact step, keeping idle layouts free of preference overhead.
    func quickStartTarget(_ step: QuickStartStep?) -> some View {
        background { QuickStartAnchorReporter(step: step).allowsHitTesting(false).accessibilityHidden(true) }
    }
}

/// Only the coaching card receives hits. The highlighted control and the rest of the application remain usable.
struct QuickStartOverlay: View {
    let step: QuickStartStep
    let targetRect: CGRect?
    var nextTitle: String? = nil
    var isBusy = false
    let onBack: () -> Void
    let onNext: () -> Void
    let onSkip: () -> Void
    let onReadSample: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cardHeight: CGFloat = 190
    @State private var lastTargetRect: CGRect?
    @State private var locationTimedOut = false
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let liveTarget = step.requiresAnchor ? visibleTarget(in: bounds) : nil
            let effectiveTarget = liveTarget ?? (step.requiresAnchor && !locationTimedOut ? lastTargetRect : nil)
            let margin = min(16, bounds.width / 12)
            let available = bounds.insetBy(dx: margin, dy: margin)
            let cardWidth = preferredWidth(in: available, target: effectiveTarget)
            let size = CGSize(width: cardWidth, height: cardHeight)
            let card = cardFrame(in: available, size: size, target: effectiveTarget)
            ZStack(alignment: .topLeading) {
                if let target = liveTarget {
                    SpotlightScrim(bounds: bounds, cutout: target)
                        .allowsHitTesting(false).accessibilityHidden(true)
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(ReaderTheme.accent, lineWidth: 2)
                        .frame(width: target.width, height: target.height)
                        .position(x: target.midX, y: target.midY)
                        .allowsHitTesting(false).accessibilityHidden(true)
                        .overlay {
                            if !reduceMotion && target.height < 96 {
                                TargetPulseRing(target: target, trigger: step)
                            }
                        }
                }

                cardContent(hasTarget: liveTarget != nil || !step.requiresAnchor)
                    .frame(width: cardWidth)
                    .background {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(ReaderTheme.surface)
                            .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14).strokeBorder(ReaderTheme.line, lineWidth: 1)
                    }
                    .onGeometryChange(for: CGFloat.self, of: { ceil($0.size.height) }) { height in
                        if abs(cardHeight - height) > 1 { cardHeight = height }
                    }
                    .position(x: card.midX, y: card.midY)
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .animation(ReaderMotion.disclosure(reduceMotion), value: step)
            .onChange(of: liveTarget) { _, next in
                if let next { lastTargetRect = next }
            }
            .task(id: step.requiresAnchor && liveTarget == nil ? step : nil) {
                locationTimedOut = false
                guard step.requiresAnchor, liveTarget == nil else { return }
                do {
                    try await Task.sleep(for: .milliseconds(700))
                    locationTimedOut = true
                } catch { return }
            }
        }
        .onChange(of: step, initial: true) { _, next in
            headingFocused = true
            if !next.requiresAnchor { lastTargetRect = nil }
        }
    }

    private func visibleTarget(in bounds: CGRect) -> CGRect? {
        guard let rect = targetRect, !rect.isEmpty, !rect.isInfinite else { return nil }
        let clipped = rect.intersection(bounds)
        guard clipped.width > 2, clipped.height > 2 else { return nil }
        return clipped.insetBy(dx: -4, dy: -4).intersection(bounds.insetBy(dx: 1, dy: 1))
    }

    private func preferredWidth(in bounds: CGRect, target: CGRect?) -> CGFloat {
        let base: CGFloat = step == .noteHover ? 368 : 332
        let standard = min(base, max(1, bounds.width))
        guard let target, target.height > bounds.height * 0.65 else { return standard }
        // A large reading canvas can leave just enough room for the guide in the adjacent sidebar.
        let availableSide = max(target.minX - bounds.minX, bounds.maxX - target.maxX) - 10
        return availableSide >= 220 ? min(standard, availableSide) : standard
    }

    private func cardFrame(in bounds: CGRect, size: CGSize, target: CGRect?) -> CGRect {
        func clamped(_ point: CGPoint) -> CGRect {
            CGRect(
                x: max(bounds.minX, min(point.x, bounds.maxX - size.width)),
                y: max(bounds.minY, min(point.y, bounds.maxY - size.height)), width: size.width, height: size.height)
        }
        guard let target else {
            if !step.requiresAnchor {
                return clamped(CGPoint(x: bounds.maxX - size.width - 8, y: bounds.maxY - size.height - 8))
            }
            return clamped(CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height))
        }
        let gap: CGFloat = 10
        let centeredX = target.midX - size.width / 2
        let centeredY = target.midY - size.height / 2
        let below = CGPoint(x: centeredX, y: target.maxY + gap)
        let above = CGPoint(x: centeredX, y: target.minY - gap - size.height)
        let right = CGPoint(x: target.maxX + gap, y: centeredY)
        let left = CGPoint(x: target.minX - gap - size.width, y: centeredY)
        // Pick the nearest clear position, preserving the whole button or selected passage whenever it fits.
        let candidates = [below, above, right, left].map(clamped)
        if let clear = candidates.first(where: { !$0.intersects(target.insetBy(dx: -4, dy: -4)) }) { return clear }
        return candidates.min { lhs, rhs in
            let a = lhs.intersection(target)
            let b = rhs.intersection(target)
            return a.width * a.height < b.width * b.height
        } ?? clamped(below)
    }

    private func cardContent(hasTarget: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("快速上手 · " + step.chapter).font(.caption.weight(.medium)).foregroundStyle(ReaderTheme.accent)
                Spacer()
                Text("\(step.rawValue + 1) / \(QuickStartStep.allCases.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(ReaderTheme.muted)
                    .accessibilityLabel("第 \(step.rawValue + 1) 步，共 \(QuickStartStep.allCases.count) 步")
            }
            Text(step.title).font(ReaderTheme.editorial(20, weight: .medium))
                .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
            Text(step.instruction).font(.callout).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(ReaderTheme.muted)
            if step == .annotation {
                NoteRecordingGuideVisual()
            } else if step == .noteHover {
                NoteHoverGuidePreview()
            }
            if !hasTarget && locationTimedOut {
                Text("暂未定位到这个入口，可继续下一步。")
                    .font(.caption).foregroundStyle(ReaderTheme.muted)
            }
            HStack(spacing: 12) {
                Button("跳过", action: onSkip).buttonStyle(.plain)
                    .foregroundStyle(ReaderTheme.muted).keyboardShortcut(.cancelAction)
                Spacer()
                if step == .importPaper {
                    Button("直接试读示例", action: onReadSample).buttonStyle(.plain)
                        .foregroundStyle(ReaderTheme.accent).disabled(isBusy)
                } else {
                    Button("上一步", action: onBack).buttonStyle(.plain)
                        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                        .disabled(isBusy)
                }
                Button(nextTitle ?? (step == QuickStartStep.allCases.last ? "完成" : "下一步"), action: onNext)
                    .buttonStyle(.borderedProminent).tint(ReaderTheme.accent)
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(isBusy)
            }
            .controlSize(.regular).padding(.top, 3)
        }
        .padding(16).foregroundStyle(ReaderTheme.ink)
        .onKeyPress(.leftArrow) {
            guard step != .importPaper, !isBusy else { return .ignored }
            onBack()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard !isBusy else { return .ignored }
            onNext()
            return .handled
        }
    }
}

/// GPU-composited 4-quad scrim avoiding per-frame full-window even-odd path tessellation.
private struct SpotlightScrim: View {
    let bounds: CGRect
    let cutout: CGRect
    private let shade = Color.black.opacity(0.14)

    var body: some View {
        let topH = max(0, cutout.minY)
        let bottomY = min(bounds.height, cutout.maxY)
        let bottomH = max(0, bounds.height - bottomY)
        let midH = max(0, bottomY - topH)
        let leftW = max(0, cutout.minX)
        let rightX = min(bounds.width, cutout.maxX)
        let rightW = max(0, bounds.width - rightX)
        ZStack(alignment: .topLeading) {
            if topH > 0 {
                shade.frame(width: bounds.width, height: topH)
            }
            if bottomH > 0 {
                shade.frame(width: bounds.width, height: bottomH).offset(y: bottomY)
            }
            if leftW > 0 && midH > 0 {
                shade.frame(width: leftW, height: midH).offset(y: topH)
            }
            if rightW > 0 && midH > 0 {
                shade.frame(width: rightW, height: midH).offset(x: rightX, y: topH)
            }
        }
    }
}

/// Pure transform/opacity pulse ring that never invalidates layout frames during animation.
private struct TargetPulseRing: View {
    let target: CGRect
    let trigger: QuickStartStep

    var body: some View {
        let scaleX = target.width > 0 ? (target.width + 12) / target.width : 1
        let scaleY = target.height > 0 ? (target.height + 12) / target.height : 1
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(ReaderTheme.accent.opacity(0.6), lineWidth: 1.5)
            .frame(width: target.width, height: target.height)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: trigger) { view, progress in
                view
                    .scaleEffect(x: 1 + (scaleX - 1) * progress, y: 1 + (scaleY - 1) * progress)
                    .opacity(1 - progress)
            } keyframes: { _ in
                MoveKeyframe(CGFloat(0))
                CubicKeyframe(CGFloat(1), duration: 0.42)
            }
            .position(x: target.midX, y: target.midY)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Compact 3-step visual cue showing how to highlight and create reading notes.
private struct NoteRecordingGuideVisual: View {
    private let swatches: [Color] = [
        Color(red: 0.95, green: 0.81, blue: 0.39),
        Color(red: 0.54, green: 0.73, blue: 0.92),
        Color(red: 0.64, green: 0.79, blue: 0.48),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                stepBadge("1", "拖选原文")
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ReaderTheme.muted)
                stepBadge("2", "点「添加笔记」")
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ReaderTheme.muted)
                stepBadge("3", "自动保存")
            }
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(Array(swatches.enumerated()), id: \.offset) { _, color in
                        Circle().fill(color).frame(width: 10, height: 10)
                    }
                }
                Text("高亮 / 下划线").font(.caption2).foregroundStyle(ReaderTheme.muted)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Image(systemName: "square.and.pencil").font(.system(size: 10))
                    Text("添加笔记 · Markdown / $公式$").font(.caption2.weight(.medium))
                }
                .foregroundStyle(ReaderTheme.accent)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(ReaderTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(ReaderTheme.line, lineWidth: 0.8) }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("记笔记流程：拖选原文，在弹出的批注浮层选择高亮颜色或点添加笔记，支持实时 Markdown 和公式并自动保存")
    }

    private func stepBadge(_ number: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(number).font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(ReaderTheme.surface)
                .frame(width: 15, height: 15)
                .background(ReaderTheme.accent, in: Circle())
            Text(label).font(.caption2.weight(.medium)).foregroundStyle(ReaderTheme.ink).lineLimit(1)
        }
    }
}

/// Interactive mini-preview demonstrating note hover: lifted wavy-underlined text, dashed curve, and expanded margin card.
private struct NoteHoverGuidePreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredPassage = false
    @State private var hoveredCard = false
    @State private var pinnedPreview = false
    @State private var userInteracted = false

    private var active: Bool { hoveredPassage || hoveredCard || pinnedPreview }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                HStack(alignment: .top, spacing: 28) {
                    // Simulated passage with hand-drawn wavy underline
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Overall rank")
                            .font(.system(size: 11)).foregroundStyle(ReaderTheme.muted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("can reverse")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(ReaderTheme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(
                                    Color(red: 0.95, green: 0.81, blue: 0.39).opacity(0.45),
                                    in: RoundedRectangle(cornerRadius: 3))
                            WavyUnderlineShape()
                                .stroke(
                                    Color(red: 0.65, green: 0.47, blue: 0.34),
                                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
                                )
                                .frame(height: 4)
                        }
                        .offset(y: active && !reduceMotion ? -2 : 0)
                        .shadow(color: .black.opacity(active ? 0.12 : 0), radius: active ? 2 : 0, y: active ? 2 : 0)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            userInteracted = true
                            hoveredPassage = inside
                            if inside { pinnedPreview = false }
                        }
                        Text("within groups.")
                            .font(.system(size: 11)).foregroundStyle(ReaderTheme.muted)
                    }
                    .frame(width: 92, alignment: .leading)
                    .padding(.top, 8)

                    // Simulated margin note card
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text("笔记").font(.system(size: 10, weight: .semibold)).foregroundStyle(
                                active ? ReaderTheme.accent : ReaderTheme.muted)
                            Spacer()
                            if active {
                                Text("点击编辑").font(.system(size: 9)).foregroundStyle(ReaderTheme.muted)
                            }
                        }
                        Text("辛普森悖论：分组权重不同导致总分反转。")
                            .font(.system(size: 10.5)).lineSpacing(1.5)
                            .foregroundStyle(ReaderTheme.ink)
                            .lineLimit(active ? 4 : 2)
                        if active {
                            Text("Σ wᵢ·sᵢ 需按难度分层核对")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(ReaderTheme.accent)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(ReaderTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                                .transition(.opacity)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        active ? ReaderTheme.surface : ReaderTheme.elevated.opacity(0.85),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(
                                active ? ReaderTheme.accent.opacity(0.75) : ReaderTheme.line,
                                lineWidth: active ? 1.2 : 0.8)
                    }
                    .shadow(color: .black.opacity(active ? 0.11 : 0.03), radius: active ? 7 : 2, y: active ? 3 : 1)
                    .offset(y: active && !reduceMotion ? -1.5 : 0)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        userInteracted = true
                        hoveredCard = inside
                        if inside { pinnedPreview = false }
                    }
                }
                .padding(10)

                // Curved dashed connector linking passage to margin note card when hovered
                if active {
                    HoverConnectorPath()
                        .stroke(
                            ReaderTheme.accent,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3.5, 3.5])
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    Circle().fill(ReaderTheme.accent)
                        .frame(width: 4.5, height: 4.5)
                        .position(x: 104, y: 41)
                        .allowsHitTesting(false)
                    Circle().fill(ReaderTheme.surface)
                        .overlay { Circle().strokeBorder(ReaderTheme.accent, lineWidth: 1.4) }
                        .frame(width: 6, height: 6)
                        .position(x: 130, y: 44)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 88)
            .background(ReaderTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(ReaderTheme.line, lineWidth: 0.8) }
            .contentShape(Rectangle())
            .onTapGesture {
                userInteracted = true
                pinnedPreview.toggle()
            }
            .animation(ReaderMotion.feedback(reduceMotion), value: active)

            HStack {
                Text(active ? "悬停态：原句轻浮 · 虚线相连 · 卡片展开" : "常态：波浪线提示 · 页边折叠摘要")
                    .font(.caption2).foregroundStyle(active ? ReaderTheme.accent : ReaderTheme.muted)
                Spacer()
                Button(active ? "查看常态" : "预览悬停态") {
                    userInteracted = true
                    hoveredPassage = false
                    hoveredCard = false
                    pinnedPreview.toggle()
                }
                .buttonStyle(.plain).font(.caption2.weight(.medium)).foregroundStyle(ReaderTheme.accent)
            }
        }
        .padding(.top, 2)
        .task {
            if reduceMotion {
                pinnedPreview = true
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(450))
                if !userInteracted { pinnedPreview = true }
            } catch {}
        }
    }
}

private struct WavyUnderlineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        path.move(to: CGPoint(x: rect.minX, y: midY))
        let step: CGFloat = 6
        var x = rect.minX
        var sign: CGFloat = 1
        while x < rect.maxX {
            let next = min(rect.maxX, x + step)
            let midX = (x + next) / 2
            path.addQuadCurve(to: CGPoint(x: next, y: midY), control: CGPoint(x: midX, y: midY + sign * 1.6))
            x = next
            sign *= -1
        }
        return path
    }
}

private struct HoverConnectorPath: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: 104, y: 41)
        let end = CGPoint(x: 130, y: 44)
        let midX = (start.x + end.x) / 2
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: midX, y: start.y), control2: CGPoint(x: midX, y: end.y))
        return path
    }
}
