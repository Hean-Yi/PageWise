import PaperReaderKit
import SwiftUI

enum QuickStartStep: Int, CaseIterable {
    case importPaper, discovery, shelves, modelSettings, bilingual, annotation, assistant, notebook

    var title: String {
        switch self {
        case .importPaper: "导入第一篇论文"
        case .discovery: "在线查找论文"
        case .shelves: "整理与预览"
        case .modelSettings: "连接模型服务"
        case .bilingual: "切换到双语阅读"
        case .annotation: "在原句旁记下想法"
        case .assistant: "打开论文助读"
        case .notebook: "回看阅读笔记"
        }
    }

    var instruction: String {
        switch self {
        case .importPaper:
            "点「导入 PDF」可添加自己的论文。也可以直接试读随应用附带的两页示例《\(DemoPaper.title)》。"
        case .discovery:
            "点加号封面，输入题名、关键词或 DOI。结果旁有「下载并导入」时，点一下就能加入书架。"
        case .shelves:
            #if os(macOS)
                "点这个加号新建书架，把封面拖到分类上。也可请「书库助理」按主题整理。指针停在封面上时，按住空格即可预览摘要。"
            #else
                "点这个加号新建书架，把封面拖到分类上。也可请「书库助理」按主题整理。长按封面，选择「预览论文」查看摘要。"
            #endif
        case .modelSettings:
            "点齿轮打开设置，在「模型服务」选择提供商，填写自己的 API 密钥并保存。翻译与助读共用这项设置。"
        case .bilingual:
            "点「双语重排」开始翻译。本地 PDF 优先翻译当前页，向下滚动即可对照阅读。点「原版」回看原始排版。"
        case .annotation:
            "在原版选中一句话，点底部的「添加笔记」。写好的批注可从「笔记」侧栏定位到原句，也可导出到 Obsidian。"
        case .assistant:
            "点「AI 精读」生成分色批注和文末总结。也可直接向「论文助读」提问，点回答里的引用核对原文。"
        case .notebook:
            "点「阅读笔记」重读精读总结，再点「原文」回到论文。想找某天读过的文章，可打开旁边的「阅读日历」。"
        }
    }
}

struct QuickStartAnchors: PreferenceKey {
    static var defaultValue: [QuickStartStep: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [QuickStartStep: Anchor<CGRect>], nextValue: () -> [QuickStartStep: Anchor<CGRect>])
    {
        value.merge(nextValue()) { _, next in next }
    }
}

extension View {
    func quickStartTarget(_ step: QuickStartStep?) -> some View {
        anchorPreference(key: QuickStartAnchors.self, value: .bounds) { anchor in
            step.map { [$0: anchor] } ?? [:]
        }
    }
}

/// Only the coaching card receives hits. The highlighted control and the rest of the application remain usable.
struct QuickStartOverlay: View {
    let step: QuickStartStep
    let targetRect: CGRect?
    var nextTitle: String? = nil
    let onBack: () -> Void
    let onNext: () -> Void
    let onSkip: () -> Void
    let onReadSample: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cardHeight: CGFloat = 154
    @State private var locationTimedOut = false
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let target = visibleTarget(in: bounds)
            let margin = min(16, bounds.width / 12)
            let available = bounds.insetBy(dx: margin, dy: margin)
            let cardWidth = preferredWidth(in: available, target: target)
            let size = CGSize(width: cardWidth, height: cardHeight)
            let card = cardFrame(in: available, size: size, target: target)
            ZStack(alignment: .topLeading) {
                if let target {
                    GuideSpotlight(target: target)
                        .fill(.black.opacity(0.16), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false).accessibilityHidden(true)
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(ReaderTheme.accent, lineWidth: 2)
                        .frame(width: target.width, height: target.height)
                        .position(x: target.midX, y: target.midY)
                        .allowsHitTesting(false).accessibilityHidden(true)
                        .overlay {
                            if !reduceMotion && target.height < 96 {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(ReaderTheme.accent.opacity(0.65), lineWidth: 1.5)
                                    .keyframeAnimator(initialValue: CGFloat(1), trigger: step) { view, progress in
                                        view.frame(
                                            width: target.width + 12 * progress, height: target.height + 12 * progress
                                        )
                                        .opacity(1 - progress)
                                    } keyframes: { _ in
                                        MoveKeyframe(CGFloat(0))
                                        CubicKeyframe(CGFloat(1), duration: 0.48)
                                    }
                                    .position(x: target.midX, y: target.midY)
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                }

                cardContent(hasTarget: target != nil)
                    .frame(width: cardWidth)
                    .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14).strokeBorder(ReaderTheme.line).allowsHitTesting(false)
                    }
                    .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { cardHeight = $0 }
                    .position(x: card.midX, y: card.midY)
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .animation(ReaderMotion.disclosure(reduceMotion), value: step)
            .animation(ReaderMotion.feedback(reduceMotion), value: target != nil)
            .animation(ReaderMotion.feedback(reduceMotion), value: target?.size)
            .task(id: target == nil ? step : nil) {
                locationTimedOut = false
                guard target == nil else { return }
                do {
                    try await Task.sleep(for: .milliseconds(800))
                    locationTimedOut = true
                } catch { return }
            }
        }
        .onChange(of: step, initial: true) { _, _ in headingFocused = true }
    }

    private func visibleTarget(in bounds: CGRect) -> CGRect? {
        guard let rect = targetRect, !rect.isEmpty, !rect.isInfinite else { return nil }
        let clipped = rect.intersection(bounds)
        guard clipped.width > 2, clipped.height > 2 else { return nil }
        return clipped.insetBy(dx: -4, dy: -4).intersection(bounds.insetBy(dx: 1, dy: 1))
    }

    private func preferredWidth(in bounds: CGRect, target: CGRect?) -> CGFloat {
        let standard = min(324, max(1, bounds.width))
        guard let target, target.height > bounds.height * 0.65 else { return standard }
        // A large reading canvas can leave just enough room for the guide in the adjacent sidebar.
        let availableSide = max(target.minX - bounds.minX, bounds.maxX - target.maxX) - 10
        return availableSide >= 210 ? min(standard, availableSide) : standard
    }

    private func cardFrame(in bounds: CGRect, size: CGSize, target: CGRect?) -> CGRect {
        func clamped(_ point: CGPoint) -> CGRect {
            CGRect(
                x: max(bounds.minX, min(point.x, bounds.maxX - size.width)),
                y: max(bounds.minY, min(point.y, bounds.maxY - size.height)), width: size.width, height: size.height)
        }
        guard let target else {
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("快速上手").font(.caption.weight(.medium)).foregroundStyle(ReaderTheme.accent)
                Spacer()
                Text("\(step.rawValue + 1) / \(QuickStartStep.allCases.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(ReaderTheme.muted)
                    .accessibilityLabel("第 \(step.rawValue + 1) 步，共 \(QuickStartStep.allCases.count) 步")
            }
            Text(step.title).font(ReaderTheme.editorial(21, weight: .medium))
                .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
            Text(step.instruction).font(.callout).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(ReaderTheme.muted)
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
                        .foregroundStyle(ReaderTheme.accent)
                } else {
                    Button("上一步", action: onBack).buttonStyle(.plain)
                        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                }
                Button(nextTitle ?? (step == .notebook ? "完成" : "下一步"), action: onNext)
                    .buttonStyle(.borderedProminent).tint(ReaderTheme.accent)
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            }
            .controlSize(.regular).padding(.top, 3)
        }
        .padding(16).foregroundStyle(ReaderTheme.ink)
        .onKeyPress(.leftArrow) {
            guard step != .importPaper else { return .ignored }
            onBack()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            onNext()
            return .handled
        }
    }
}

private struct GuideSpotlight: Shape {
    var target: CGRect

    var animatableData: CGRect.AnimatableData {
        get { target.animatableData }
        set { target.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: target, cornerSize: CGSize(width: 9, height: 9))
        return path
    }
}
