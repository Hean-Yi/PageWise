import PaperReaderKit
import SwiftUI

enum ShelfPreviewTarget: Equatable {
    case held(UUID)
    case pinned(UUID)

    var paperID: UUID {
        switch self {
        case .held(let id), .pinned(let id): id
        }
    }
}

struct ShelfPaperPreview: View {
    let paper: Paper
    let model: ReaderModel
    let flight: ShelfCoverFlight
    let lift: () -> Void
    let dismiss: () -> Void
    let landed: () -> Void
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var content: PaperPreviewContent?
    @State private var useLiveCover = false
    @State private var revealProgress: CGFloat = 0

    var body: some View {
        GeometryReader { viewport in
            let size = viewport.size
            let panelWidth = min(916, max(0, size.width - (size.width > 650 ? 56 : 24)))
            let wide = panelWidth >= 575
            let panelHeight = min(max(0, size.height - 32), wide ? 506 : 690)
            let coverWidth =
                wide
                ? min(ShelfCoverFlight.maximumPreviewWidth, panelWidth * 0.34, max(0, panelHeight - 64) * 0.7)
                : min(205, panelWidth * 0.55, panelHeight * 0.33)

            let panel = CGRect(
                x: (size.width - panelWidth) / 2, y: (size.height - panelHeight) / 2,
                width: panelWidth, height: panelHeight)
            let coverHeight = coverWidth / 0.7
            let destination = CGRect(
                x: wide ? panel.minX + 26 : panel.midX - coverWidth / 2,
                y: wide ? panel.midY - coverHeight / 2 : panel.minY + 18, width: coverWidth, height: coverHeight)

            ZStack {
                Color.black.opacity(0.22)
                    .modifier(PreviewFade(progress: revealProgress, range: 0...0.7))
                    .contentShape(Rectangle()).onTapGesture(perform: dismiss).accessibilityHidden(true)
                previewPanel(wide: wide, size: panel.size, cover: destination.size)
                    .modifier(PreviewFade(progress: revealProgress, range: 0.13...0.78))
                    .allowsHitTesting(!flight.returning)
                let reading = ReadingProgress.resolve(paper: paper, workspace: model.workspace(for: paper.id))
                if reduceMotion || useLiveCover {
                    BookCoverView(paper: paper, progress: reading)
                        .frame(width: coverWidth, height: coverHeight)
                        .position(x: destination.midX, y: destination.midY).allowsHitTesting(false)
                        .opacity(flight.awaitingLift ? 0 : 1)
                        .onAppear { if flight.awaitingLift { lift() } }
                } else {
                    ShelfFlyingCover(
                        paper: paper, reading: reading, flight: flight, destination: destination,
                        reduceMotion: reduceMotion
                    ) { rendered in
                        useLiveCover = !rendered
                        lift()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(flight.awaitingLift ? 0 : 1)
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("书目预览，" + paper.title)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, dismiss)
        .task(id: paper.id) {
            let value = await model.previewContent(for: paper.id)
            guard !Task.isCancelled else { return }
            withAnimation(ReaderMotion.feedback(reduceMotion)) { content = value }
        }
        .task(id: flight) {
            guard !flight.awaitingLift else { return }
            let remaining = max(0, flight.endsAt.timeIntervalSinceNow)
            let moving = !reduceMotion && !useLiveCover
            withAnimation(moving ? .linear(duration: remaining) : nil) {
                revealProgress = flight.returning ? 0 : 1
            }
            if flight.returning {
                if moving { try? await Task.sleep(for: .seconds(remaining)) }
                guard !Task.isCancelled else { return }
                landed()
            }
        }
    }

    private func previewPanel(wide: Bool, size: CGSize, cover: CGSize) -> some View {
        let space = Color.clear.frame(width: cover.width, height: cover.height)
            .accessibilityElement(children: .ignore).accessibilityLabel(paper.title).accessibilityAddTraits(.isHeader)
        let text = details.modifier(PreviewFade(progress: revealProgress, range: 0.37...0.93))
        return Group {
            if wide {
                HStack(spacing: 0) {
                    space.padding(.horizontal, 26)
                    Divider().overlay(ReaderTheme.line)
                    text.padding(.leading, 26).padding(.trailing, 30)
                }
            } else {
                VStack(spacing: 12) {
                    space.padding(.top, 18)
                    text.padding(.horizontal, 20)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .background {
            RoundedRectangle(cornerRadius: 16).fill(ReaderTheme.surface)
                .shadow(color: .black.opacity(0.16), radius: 22, y: 9)
        }
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(ReaderTheme.line).allowsHitTesting(false) }
        .overlay(alignment: .topTrailing) {
            Button("关闭书目预览", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly).readerFloatingButton(.circle)
                .padding(6).help("关闭预览")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let sentence = content?.oneSentence {
                        Label("一句话概括", systemImage: "sparkles")
                            .font(.caption.weight(.semibold)).foregroundStyle(ReaderTheme.accent)
                        Text(sentence).font(ReaderTheme.editorial(21, weight: .medium)).lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider().padding(.vertical, 3)
                    }
                    Text(content?.isChineseAbstract == false && content?.abstract != nil ? "Abstract" : "摘要")
                        .font(ReaderTheme.editorial(25, weight: .medium)).accessibilityAddTraits(.isHeader)
                    if let content {
                        if let text = content.abstract {
                            Text(text).font(ReaderTheme.editorial(17)).lineSpacing(6)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("未能从这篇论文中识别出摘要。").font(.callout).foregroundStyle(ReaderTheme.muted)
                        }
                    } else {
                        ProgressView().controlSize(.small).accessibilityLabel("正在读取摘要")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().padding(.vertical, 12)
            Button(action: open) {
                HStack(spacing: 6) {
                    Text("打开论文")
                    Image(systemName: "arrow.right")
                }
                .font(.callout.weight(.medium)).foregroundStyle(ReaderTheme.accent)
            }.buttonStyle(.plain)
        }
        .foregroundStyle(ReaderTheme.ink)
        .padding(.top, 30).padding(.bottom, 20)
    }
}

/// The background, panel and text retrace the cover's progress even when Space reverses mid-flight.
private struct PreviewFade: ViewModifier, Animatable {
    nonisolated var progress: CGFloat
    let range: ClosedRange<CGFloat>

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.opacity(Double(ShelfCoverFlight.ease(progress, from: range.lowerBound, to: range.upperBound)))
    }
}
