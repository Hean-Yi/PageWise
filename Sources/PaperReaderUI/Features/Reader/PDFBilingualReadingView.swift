import PaperReaderKit
import SwiftUI

enum PDFBilingualLayoutPreference: String {
    case auto, split, stacked, paragraph

    func resolved(at width: CGFloat) -> PDFSentenceTextCanvas.Layout {
        switch self {
        case .auto: width >= 740 ? .split : .stacked
        case .split: width >= 570 ? .split : .stacked
        case .stacked: .stacked
        case .paragraph: .paragraph
        }
    }
}

struct PDFBilingualReadingView: View {
    let model: ReaderModel
    let penEnabled: Bool
    let openSettings: () -> Void

    @Binding var layout: PDFBilingualLayoutPreference
    @Binding var peekingAtOriginal: Bool
    @AppStorage("PDFBilingualFontSize") private var fontSize = 16
    @SceneStorage("PDFBilingualOriginalFraction") private var originalFraction = 0.53
    @State private var dragStart: Double?
    @Environment(\.layoutDirection) private var layoutDirection

    private var session: PDFBilingualSession { model.pdfBilingual }

    private var paragraphVisible: Bool { session.isOpen && layout == .paragraph && !peekingAtOriginal }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let textLayout = layout.resolved(at: width)
            let spread = textLayout == .split && session.isOpen && !peekingAtOriginal
            let pdfVisible = !session.isOpen || peekingAtOriginal || spread
            let pdfWidth = spread ? min(width - 268, max(240, width * originalFraction)) : width
            HStack(spacing: 0) {
                PDFCanvas(model: model, penEnabled: pdfVisible && penEnabled, acceptsSentenceInput: pdfVisible)
                    .frame(maxWidth: session.isOpen ? .infinity : 820)
                    .frame(width: pdfWidth)
                    .frame(width: pdfVisible ? pdfWidth : 0)
                    .clipped()
                    .opacity(pdfVisible ? 1 : 0)
                    .allowsHitTesting(pdfVisible)
                    .accessibilityHidden(!pdfVisible)
                if session.isOpen && (!peekingAtOriginal || textLayout == .paragraph) {
                    if spread { splitter(width: width).frame(width: 8) }
                    pane(textLayout: textLayout, allowsSplit: width >= 570)
                        // Keep the paragraph canvas at its reading width and scroll position during a source peek.
                        .frame(width: textLayout == .paragraph ? width : nil)
                        .frame(width: peekingAtOriginal ? 0 : nil)
                        .clipped()
                        .opacity(peekingAtOriginal ? 0 : 1)
                        .allowsHitTesting(!peekingAtOriginal)
                        .accessibilityHidden(peekingAtOriginal)
                }
            }
            .overlay(alignment: .topTrailing) {
                if session.isOpen && peekingAtOriginal {
                    Button {
                        peekingAtOriginal = false
                    } label: {
                        Label(layout == .paragraph ? "返回段落重排" : "返回逐句对照", systemImage: "arrow.uturn.backward")
                            .font(.callout.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent).tint(ReaderTheme.accent).padding(16)
                }
            }
            .onChange(of: pdfVisible) { _, visible in
                session.hover(nil)
                if visible, let id = session.focusedID { session.focus(id) }
            }
        }
        .onChange(of: paragraphVisible, initial: true) { _, visible in
            if visible {
                session.prepareParagraphReading(model)
                session.consumeParagraphJump(model)
            }
        }
        .onChange(of: model.jumpPage) { _, _ in
            if paragraphVisible { session.consumeParagraphJump(model) }
        }
        .onChange(of: session.isOpen) { _, _ in peekingAtOriginal = false }
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

    private func pane(textLayout: PDFSentenceTextCanvas.Layout, allowsSplit: Bool) -> some View {
        let split = textLayout == .split
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
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(split ? "简体中文" : (paragraphs ? "英汉段落对照" : "英汉对照")).font(.headline)
                    Text(pageStatus(total: sentences.count, completed: translations.count))
                        .font(.caption).foregroundStyle(ReaderTheme.muted).monospacedDigit()
                }
                Spacer(minLength: 4)
                if !split && (paragraphs || !translations.isEmpty) {
                    Button {
                        peekingAtOriginal = true
                    } label: {
                        Label("查看原页", systemImage: "doc.text.magnifyingglass")
                    }.help("查看原页").accessibilityLabel("查看原页")
                }
                Menu {
                    Picker("对照布局", selection: $layout) {
                        Label("段落重排", systemImage: "text.alignleft").tag(PDFBilingualLayoutPreference.paragraph)
                        Label("逐句上下", systemImage: "rectangle.split.1x2").tag(PDFBilingualLayoutPreference.stacked)
                        Label("左右并排", systemImage: "rectangle.split.2x1")
                            .tag(PDFBilingualLayoutPreference.split).disabled(!allowsSplit)
                        Text("随窗口调整").tag(PDFBilingualLayoutPreference.auto)
                    }
                    Divider()
                    Menu("译文字号") {
                        Picker("译文字号", selection: $fontSize) {
                            Text("小").tag(14)
                            Text("标准").tag(16)
                            Text("大").tag(19)
                        }
                    }
                    if split {
                        Toggle(
                            "跟随原句", isOn: Binding(get: { session.followsScroll }, set: { session.followsScroll = $0 }))
                    }
                } label: {
                    Image(
                        systemName: paragraphs
                            ? "text.alignleft" : (split ? "rectangle.split.2x1" : "rectangle.split.1x2"))
                }.fixedSize().help("对照布局与译文字号").accessibilityLabel("对照布局")
            }
            .buttonStyle(.borderless).padding(.horizontal, 22).padding(.vertical, 14)
            Divider()
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
                selectionResult(source, sentences: sentences)
            }
            if !paragraphs && translations.isEmpty {
                emptyPage(hasSentences: !sentences.isEmpty, showsPageAction: showsPageAction)
            } else {
                PDFSentenceTextCanvas(
                    sentences: sentences, translations: translations,
                    layout: textLayout, fontSize: fontSize, activeID: session.activeID, focusedID: session.focusedID,
                    focusRevision: session.sourceFocusRevision, followsScroll: session.followsScroll,
                    sourceScrollID: session.sourceScrollID, sourceScrollRevision: session.sourceScrollRevision,
                    pdfSelectedIDs: session.pdfSelectedIDs,
                    onScroll: { id in
                        if paragraphs {
                            if paragraphVisible { session.scrollFromParagraph(id) }
                        } else {
                            session.scrollFromTranslation(id)
                        }
                    },
                    onSelection: session.selectFromTranslation,
                    onFocus: { id in
                        if paragraphs {
                            if paragraphVisible { session.focusParagraphSentence(id, model: model) }
                        } else {
                            session.focus(id)
                        }
                    }, onHover: session.hover,
                    illustrations: session.illustrations,
                    onRevealIllustration: { item in
                        if paragraphs {
                            session.revealParagraphIllustration(item, model: model)
                        } else {
                            session.revealIllustration(item)
                        }
                        peekingAtOriginal = true
                    }, continuous: paragraphs ? paragraphDocument : nil)
                if showsPageAction && session.selectionSource == nil && !sentences.isEmpty
                    && (session.isTranslating || translations.count < sentences.count)
                {
                    Divider()
                    HStack(spacing: 12) {
                        translationActions(continuing: !translations.isEmpty)
                        if !session.isTranslating { serviceDisclosure }
                    }.padding(.horizontal, 20).padding(.vertical, 10)
                }
            }
            if let documentStatus, let paperID = model.selectedPaperID {
                documentBar(documentStatus, paperID: paperID)
            } else if paragraphs && session.selectionSource == nil {
                Divider()
                Button("翻译全文") { session.setParagraphLayout(true, model: model) }
                    .buttonStyle(.borderless).padding(.horizontal, 20).padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ReaderTheme.surface)
    }

    private var paragraphDocument: PDFSentenceTextCanvas.Continuous? {
        guard let paper = model.paper else { return nil }
        return PDFSentenceTextCanvas.Continuous(
            paperID: paper.id, pageCount: paper.pageCount, pages: session.paragraphPages,
            targetPage: session.paragraphJumpPage, jumpRevision: session.paragraphJumpRevision,
            onVisiblePage: { page in
                if paragraphVisible { session.paragraphDidScroll(to: page, model: model) }
            },
            onOpenOriginalPage: { page in
                session.revealParagraphPage(page, model: model)
                peekingAtOriginal = true
            })
    }

    private func documentBar(_ status: PDFDocumentTranslationStatus, paperID: UUID) -> some View {
        let progress = status.progress
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 10) {
                Image(
                    systemName: status.phase == .completed && progress.partialPages == 0
                        ? "checkmark.circle" : "character.bubble"
                )
                .foregroundStyle(ReaderTheme.accent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(documentSummary(status)).font(.caption).monospacedDigit()
                    if case .failed(let reason) = status.phase {
                        Text(reason).font(.caption).foregroundStyle(ReaderTheme.muted).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 4)
                switch status.phase {
                case .needsConfiguration:
                    Button("设置翻译", action: openSettings)
                case .running:
                    Button("暂停") { model.pdfDocumentTranslation.pause(paperID) }
                case .paused:
                    Button("继续翻译") { session.resumeDocumentTranslation(model) }
                case .failed:
                    if !model.translationSettings.model.isEmpty {
                        Button("重试") { session.resumeDocumentTranslation(model) }
                    }
                    Button("模型设置", action: openSettings)
                case .completed:
                    if progress.partialPages > 0 {
                        Button("重试缺译部分") { session.resumeDocumentTranslation(model) }
                    }
                }
            }
            .buttonStyle(.borderless).padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 8)
        }
    }

    private func documentSummary(_ status: PDFDocumentTranslationStatus) -> String {
        let progress = status.progress
        let count = "\(progress.processedPages) / \(progress.pageCount) 页"
        switch status.phase {
        case .needsConfiguration: return "配置翻译服务后可自动补译"
        case .running:
            if let page = progress.activePageIndex { return "全文 \(count) · 正在处理第 \(page + 1) 页" }
            return "全文 \(count) · 正在准备"
        case .paused: return "全文已暂停 · \(count)"
        case .failed: return "全文翻译中断 · \(count)"
        case .completed:
            var parts = ["全文已处理 \(progress.pageCount) 页"]
            if progress.partialPages > 0 { parts.append("\(progress.partialPages) 页有缺译") }
            if progress.skippedPages > 0 { parts.append("\(progress.skippedPages) 页保留原版") }
            return parts.joined(separator: " · ")
        }
    }

    private func pageStatus(total: Int, completed: Int) -> String {
        let page = "原页 \(model.visiblePage + 1)"
        guard total > 0 else { return page }
        if completed == 0 { return "\(page) · \(total) 句" }
        if completed == total { return "\(page) · 已译 \(completed) 句" }
        return "\(page) · 已译 \(completed) / \(total) 句"
    }

    private func emptyPage(hasSentences: Bool, showsPageAction: Bool) -> some View {
        VStack(spacing: 14) {
            if session.isLoading {
                ProgressView().controlSize(.small)
                Text("正在读取本页文字").font(.callout).foregroundStyle(ReaderTheme.muted)
            } else if !hasSentences {
                Image(systemName: "doc.text.viewfinder").font(.title2).foregroundStyle(ReaderTheme.muted)
                Text(layout == .paragraph ? "本页暂无可重排的文字" : "本页暂无可逐句对照的文字").font(.headline)
                if layout != .paragraph {
                    Button("查看原页") { peekingAtOriginal = true }.buttonStyle(.bordered)
                }
            } else {
                Image(systemName: "text.bubble").font(.system(size: 26, weight: .light)).foregroundStyle(
                    ReaderTheme.accent)
                if showsPageAction {
                    translationActions(continuing: false)
                    if !session.isTranslating { serviceDisclosure.multilineTextAlignment(.center) }
                } else {
                    Text("本页译文就绪后会在这里显示").font(.callout).foregroundStyle(ReaderTheme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private var serviceDisclosure: some View {
        let name = model.translationSettings.model
        return Text(name.isEmpty ? "配置模型后可翻译本页英文" : "本页英文将发送至 \(name)")
            .font(.caption).foregroundStyle(ReaderTheme.muted).textSelection(.enabled)
    }

    @ViewBuilder private func translationActions(continuing: Bool) -> some View {
        if session.isTranslating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在翻译").font(.callout)
                Button("暂停") { session.pause() }.buttonStyle(.borderless).padding(.leading, 5)
            }
        } else {
            Button {
                if model.translationSettings.model.isEmpty {
                    openSettings()
                } else {
                    session.translatePage(model, paragraphs: layout == .paragraph)
                }
            } label: {
                Label(continuing ? "继续翻译本页" : "翻译本页", systemImage: "character.bubble")
                    .padding(.horizontal, 5).padding(.vertical, 3)
            }.buttonStyle(.borderedProminent).tint(ReaderTheme.accent).disabled(session.isLoading)
        }
    }

    private func selectionResult(_ source: String, sentences: [PDFSourceSentence]) -> some View {
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
                    Image(systemName: "xmark").padding(4)
                }
                .buttonStyle(.plain).foregroundStyle(ReaderTheme.muted)
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
            if let id = session.selectionContextID, sentences.contains(where: { $0.id == id }) {
                Button("对照整句") { session.showSelectionContext() }
                    .buttonStyle(.borderless).font(.caption.weight(.medium))
                    .help("查看这一句已保存的英文和译文")
            }
        }.padding(16).background(ReaderTheme.accent.opacity(0.045))
    }
}
