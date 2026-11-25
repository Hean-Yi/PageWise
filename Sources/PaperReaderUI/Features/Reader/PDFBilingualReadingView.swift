import PaperReaderKit
import SwiftUI

enum PDFBilingualLayoutPreference: RawRepresentable, Equatable {
    case paragraph, split

    init?(rawValue: String) {
        switch rawValue {
        case "split": self = .split
        case "paragraph", "stacked", "auto": self = .paragraph
        default: return nil
        }
    }

    var rawValue: String {
        switch self {
        case .split: "split"
        case .paragraph: "paragraph"
        }
    }

    func resolved(at width: CGFloat) -> PDFSentenceTextCanvas.Layout {
        self == .split && width >= 570 ? .split : .paragraph
    }
}

struct PDFBilingualReadingView: View {
    let model: ReaderModel
    let penEnabled: Bool
    let sidebarOpen: Bool
    let openSettings: () -> Void

    @Binding var layout: PDFBilingualLayoutPreference
    @Binding var peekingAtOriginal: Bool
    @AppStorage("PDFBilingualFontSize") private var fontSize = 16
    @SceneStorage("PDFBilingualOriginalFraction") private var originalFraction = 0.53
    @State private var dragStart: Double?
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var session: PDFBilingualSession { model.pdfBilingual }

    private var paragraphVisible: Bool { session.isOpen && !peekingAtOriginal }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let textLayout = layout.resolved(at: width)
            let historicalInk =
                textLayout == .paragraph && !peekingAtOriginal ? session.historicalHighlights(in: model) : []
            let spread = textLayout == .split && session.isOpen && !peekingAtOriginal
            let pdfVisible = !session.isOpen || peekingAtOriginal || spread
            let pdfWidth = spread ? min(width - 268, max(240, width * originalFraction)) : width
            ZStack(alignment: .leading) {
                PDFCanvas(model: model, penEnabled: pdfVisible && penEnabled, isReaderVisible: pdfVisible)
                    .frame(maxWidth: spread ? .infinity : 820)
                    .frame(width: pdfWidth)
                    .allowsHitTesting(pdfVisible)
                    .accessibilityHidden(!pdfVisible)
                ZStack {
                    if session.isOpen && (!peekingAtOriginal || textLayout == .paragraph) {
                        HStack(spacing: 0) {
                            if spread {
                                Color.clear.frame(width: pdfWidth).allowsHitTesting(false)
                                splitter(width: width).frame(width: 8)
                            }
                            pane(textLayout: textLayout)
                        }
                        // Fade the surface as a unit. PDFKit and WebKit lay out once at their final widths.
                        .transaction { $0.animation = nil }
                        .opacity(peekingAtOriginal ? 0 : 1)
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(ReaderMotion.navigation(reduceMotion), value: session.isOpen)
                .animation(ReaderMotion.navigation(reduceMotion), value: peekingAtOriginal)
                .allowsHitTesting(session.isOpen && !peekingAtOriginal)
                .accessibilityHidden(!session.isOpen || peekingAtOriginal)
            }
            .overlay(alignment: .topTrailing) {
                ZStack {
                    if session.isOpen && peekingAtOriginal {
                        Button {
                            peekingAtOriginal = false
                        } label: {
                            Label("返回双语重排", systemImage: "arrow.uturn.backward").labelStyle(
                                ReaderSymbolLabelStyle(motion: .left)
                            )
                            .font(.callout.weight(.medium))
                        }
                        .readerFloatingButton(.capsule).padding(16)
                        .transition(.opacity)
                    }
                }
                .animation(ReaderMotion.feedback(reduceMotion), value: peekingAtOriginal)
                .allowsHitTesting(session.isOpen && peekingAtOriginal)
            }
            .onChange(of: session.isOpen && textLayout == .paragraph && !peekingAtOriginal, initial: true) {
                _, visible in
                if visible {
                    session.prepareParagraphReading(model)
                    session.consumeParagraphJump(model)
                }
            }
            .onChange(of: model.jumpPage) { _, _ in
                if paragraphVisible && textLayout == .paragraph { session.consumeParagraphJump(model) }
            }
            .task(id: historicalInk) { await session.locateHistoricalInk(historicalInk, model: model) }
            .onChange(of: model.outlineArrival?.revision) { _, _ in
                if paragraphVisible && textLayout == .paragraph { session.consumeParagraphJump(model) }
            }
        }
        .onChange(of: session.isOpen) { _, open in
            peekingAtOriginal = false
            if !open, model.pdfNoteEditor?.usesReflowMargin == true { model.closePDFReadingNote() }
        }
        .onChange(of: model.readingNoteNavigationToken) { _, _ in
            if model.pdfNoteEditor?.usesReflowMargin == true { peekingAtOriginal = false }
        }
        .onChange(of: session.selectionRequestRevision) { _, _ in peekingAtOriginal = false }
        .onChange(of: layout) { _, newLayout in
            peekingAtOriginal = false
            if session.isOpen { session.setParagraphLayout(newLayout == .paragraph, model: model) }
        }
    }

    private func splitter(width: CGFloat) -> some View {
        Rectangle().fill(ReaderTheme.canvas)
            .overlay(Rectangle().fill(ReaderTheme.line).frame(width: 1))
            .overlay(Capsule().fill(ReaderTheme.muted.opacity(0.45)).frame(width: 3, height: 28))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? originalFraction
                        dragStart = start
                        let offset = value.translation.width * (layoutDirection == .rightToLeft ? -1 : 1)
                        let minFraction = max(0.32, 240 / width)
                        let maxFraction = min(0.68, 1 - 260 / width)
                        originalFraction = min(maxFraction, max(minFraction, start + offset / width))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .accessibilityLabel("调整原页和译文宽度")
            .accessibilityAdjustableAction { direction in
                originalFraction = min(0.62, max(0.42, originalFraction + (direction == .increment ? 0.03 : -0.03)))
            }
    }

    private func pane(textLayout: PDFSentenceTextCanvas.Layout) -> some View {
        let paragraphs = textLayout == .paragraph
        let documentStatus = model.selectedPaperID.flatMap { model.pdfDocumentTranslation.status(for: $0) }
        let showsPageAction = !paragraphs && (documentStatus == nil || documentStatus?.phase == .completed)
        let sentences = paragraphs ? session.paragraphSentences : session.sentences
        let cached = session.translations
        let translations =
            paragraphs
            ? Dictionary(
                uniqueKeysWithValues: sentences.compactMap { sentence in
                    cached[sentence.id].map { (sentence.id, $0) }
                }) : cached
        return VStack(alignment: .leading, spacing: 0) {
            if !paragraphs, let notice = session.notice {
                Text(notice).font(.caption).foregroundStyle(ReaderTheme.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20).padding(.top, 8)
            }
            if let error = session.error {
                HStack(alignment: .firstTextBaseline) {
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button("模型设置", action: openSettings).fixedSize()
                }
                .padding(12).background(ReaderTheme.accent.opacity(0.07))
            }
            if let source = session.selectionSource {
                selectionResult(source)
            }
            if !paragraphs && translations.isEmpty {
                emptyPage(hasSentences: !sentences.isEmpty, showsPageAction: showsPageAction)
                    .onChange(of: unlocatedSplitNote, initial: true) { _, id in
                        if let id { model.useOriginalPDFNoteCard(for: id) }
                    }
            } else {
                PDFSentenceTextCanvas(
                    sentences: sentences, translations: translations,
                    layout: textLayout, fontSize: fontSize,
                    onSelection: model.selectBilingualSentences,
                    illustrations: session.illustrations,
                    onRevealIllustration: { item in
                        if paragraphs {
                            session.revealParagraphIllustration(item, model: model)
                        } else {
                            session.revealIllustration(item)
                        }
                        peekingAtOriginal = true
                    }, continuous: paragraphs ? paragraphDocument : nil,
                    inlineNotes: model.reflowInlinePDFNotes,
                    onOpenNote: { id in
                        guard let note = model.currentReadingNotes.first(where: { $0.id == id }) else { return }
                        model.openReadingNote(note, onOriginalPDF: true)
                    },
                    onOpenHighlight: { id in
                        guard let mark = model.currentHighlights.first(where: { $0.id == id }) else { return }
                        model.openPDFHighlightNote(mark, inReflow: true)
                    }, inlineHighlights: model.inlinePDFHighlights,
                    onTextSelection: { session.reflowTextSelection = $0 },
                    onSelectionAction: { action, selection in
                        let paperID = model.paper?.id
                        Task {
                            guard let paperID, model.paper?.id == paperID else { return }
                            await model.performReflowSelectionAction(action, selection: selection)
                        }
                    }, noteModel: model, sidebarOpen: sidebarOpen)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ReaderTheme.surface)
    }

    // The untranslated side-by-side pane has no WebKit surface to resolve a saved note.
    private var unlocatedSplitNote: UUID? {
        guard !session.isLoading, let editor = model.pdfNoteEditor, editor.usesReflowMargin,
            editor.note.anchors.first?.readingPageIndex == session.pageIndex
        else { return nil }
        return editor.id
    }

    private var paragraphDocument: PDFSentenceTextCanvas.Continuous? {
        guard let paper = model.paper else { return nil }
        return PDFSentenceTextCanvas.Continuous(
            paperID: paper.id, pageCount: paper.pageCount, pages: session.paragraphPages,
            targetPage: session.paragraphJumpPage, jumpRevision: session.paragraphJumpRevision,
            outlineItem: session.paragraphJumpItem,
            onVisiblePage: { page in
                if paragraphVisible { session.paragraphDidScroll(to: page, model: model) }
            },
            onOpenOriginalPage: { page in
                session.revealParagraphPage(page, model: model)
                peekingAtOriginal = true
            })
    }

    private func emptyPage(hasSentences: Bool, showsPageAction: Bool) -> some View {
        VStack(spacing: 14) {
            if session.isLoading {
                ProgressView().controlSize(.small)
                Text("正在读取本页文字").font(.callout).foregroundStyle(ReaderTheme.muted)
            } else if !hasSentences {
                Image(systemName: "doc.text.viewfinder").font(.title2).foregroundStyle(ReaderTheme.muted)
                Text("本页暂无可重排的文字").font(.headline)
                if layout != .paragraph {
                    Button("查看原页") { peekingAtOriginal = true }.buttonStyle(.bordered)
                }
            } else {
                Image(systemName: "text.bubble").font(.system(size: 26, weight: .light)).foregroundStyle(
                    ReaderTheme.accent)
                if showsPageAction {
                    PDFPageTranslationAction(model: model, openSettings: openSettings)
                        .buttonStyle(.borderedProminent).tint(ReaderTheme.accent)
                    if !session.isTranslating { serviceDisclosure.multilineTextAlignment(.center) }
                } else {
                    Text("本页译文就绪后会在这里显示").font(.callout).foregroundStyle(ReaderTheme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private var serviceDisclosure: some View {
        let name = model.modelSettings.model
        return Text(name.isEmpty ? "配置模型后可翻译本页英文" : "本页英文将发送至 \(name)")
            .font(.caption).foregroundStyle(ReaderTheme.muted).textSelection(.enabled)
    }

    private func selectionResult(_ source: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("选区译文").font(.caption.weight(.semibold)).foregroundStyle(ReaderTheme.accent)
                if session.isTranslating && session.selectionTranslation == nil {
                    ProgressView().controlSize(.small)
                    Text("正在翻译选区").font(.caption).foregroundStyle(ReaderTheme.muted)
                }
                Spacer()
                Button {
                    session.dismissSelection()
                } label: {
                    ReaderIcon(.close, size: 14).padding(4)
                }
                .readerIconButtonStyle(.plain).foregroundStyle(ReaderTheme.muted)
                .accessibilityLabel("关闭选区译文").help("关闭选区译文")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    Text(source).font(.callout.italic()).foregroundStyle(ReaderTheme.muted).textSelection(.enabled)
                    if let result = session.selectionTranslation {
                        Text(result).font(.body).lineSpacing(4).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 140).fixedSize(horizontal: false, vertical: true)

        }.padding(16).background(ReaderTheme.accent.opacity(0.045))
    }
}
