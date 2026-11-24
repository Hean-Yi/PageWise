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
    @State private var backdropVisible = false
    @State private var panelVisible = false
    @State private var detailsVisible = false

    var body: some View {
        GeometryReader { viewport in
            let size = viewport.size
            let panelWidth = min(916, max(0, size.width - (size.width > 650 ? 56 : 24)))
            let wide = panelWidth >= 575
            let panelHeight = min(max(0, size.height - 32), wide ? 506 : 690)
            let coverWidth =
                wide
                ? min(282, panelWidth * 0.34, max(0, panelHeight - 64) * 0.7)
                : min(205, panelWidth * 0.55, panelHeight * 0.33)

            let panel = CGRect(
                x: (size.width - panelWidth) / 2, y: (size.height - panelHeight) / 2,
                width: panelWidth, height: panelHeight)
            let coverHeight = coverWidth / 0.7
            let destination = CGRect(
                x: wide ? panel.minX + 26 : panel.midX - coverWidth / 2,
                y: wide ? panel.midY - coverHeight / 2 : panel.minY + 18, width: coverWidth, height: coverHeight)

            ZStack {
                Color.black.opacity(backdropVisible ? 0.22 : 0)
                    .contentShape(Rectangle()).onTapGesture(perform: dismiss).accessibilityHidden(true)
                previewPanel(wide: wide, size: panel.size, cover: destination.size)
                    .opacity(panelVisible ? 1 : 0).allowsHitTesting(!flight.returning)
                let reading = ReadingProgress.resolve(paper: paper, workspace: model.workspace(for: paper.id))
                if useLiveCover {
                    BookCoverView(paper: paper, progress: reading)
                        .frame(width: coverWidth, height: coverHeight)
                        .position(x: destination.midX, y: destination.midY).allowsHitTesting(false)
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
        .task(id: flight) {
            guard !flight.awaitingLift else { return }
            let opening = !flight.returning
            let remaining = max(0, flight.endsAt.timeIntervalSinceNow)
            let timing = { (portion: Double, delay: Double) -> Animation? in
                reduceMotion || useLiveCover ? nil : .easeInOut(duration: remaining * portion).delay(remaining * delay)
            }
            withAnimation(timing(0.8, 0)) { backdropVisible = opening }
            withAnimation(timing(opening ? 0.65 : 0.7, opening ? 0.17 : 0.06)) { panelVisible = opening }
            withAnimation(timing(opening ? 0.46 : 0.42, opening ? 0.44 : 0)) { detailsVisible = opening }
            do {
                if !reduceMotion && !useLiveCover { try await Task.sleep(for: .seconds(remaining)) }
                try Task.checkCancellation()
            } catch { return }
            if flight.returning {
                landed()
            } else if content == nil {
                // Let the book land before PDF extraction or a long abstract enters the view tree.
                let value = await model.previewContent(for: paper.id)
                if !Task.isCancelled { content = value }
            }
        }
    }

    private func previewPanel(wide: Bool, size: CGSize, cover: CGSize) -> some View {
        let space = Color.clear.frame(width: cover.width, height: cover.height)
            .accessibilityElement(children: .ignore).accessibilityLabel(paper.title).accessibilityAddTraits(.isHeader)
        let text = details.opacity(detailsVisible ? 1 : 0)
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
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(ReaderTheme.muted).padding(6)
            .accessibilityLabel("关闭书目预览").help("关闭预览")
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
