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
    let covers: Namespace.ID
    let dismiss: () -> Void
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var content: PaperPreviewContent?
    @State private var revealText = false

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

            ZStack {
                Color.black.opacity(0.22).ignoresSafeArea()
                    .onTapGesture(perform: dismiss).accessibilityHidden(true)
                    .transition(.opacity)
                Group {
                    if wide {
                        HStack(spacing: 0) {
                            cover(width: coverWidth).padding(.horizontal, 26)
                            Divider().overlay(ReaderTheme.line)
                            details.padding(.leading, 26).padding(.trailing, 30)
                        }
                    } else {
                        VStack(spacing: 12) {
                            cover(width: coverWidth).padding(.top, 18)
                            details.padding(.horizontal, 20)
                        }
                    }
                }
                .frame(width: panelWidth, height: panelHeight)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("书目预览，" + paper.title)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, dismiss)
        .task(id: paper.id) {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16).delay(0.1)) { revealText = true }
            let value = await model.previewContent(for: paper.id)
            if !Task.isCancelled { content = value }
        }
    }

    private func cover(width: CGFloat) -> some View {
        BookCoverView(paper: paper)
            .matchedGeometryEffect(id: paper.id, in: covers)
            .frame(width: width, height: width / 0.7)
            .shadow(color: .black.opacity(0.16), radius: 10, x: 1, y: 7)
            .accessibilityHidden(false).accessibilityElement(children: .ignore)
            .accessibilityLabel(paper.title).accessibilityAddTraits(.isHeader)
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
        .opacity(revealText ? 1 : 0)
    }
}
