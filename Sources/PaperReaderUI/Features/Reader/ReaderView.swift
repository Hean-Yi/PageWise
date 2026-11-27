import PaperReaderKit
import SwiftUI

struct ReaderView: View {
    @Bindable var model: ReaderModel
    let sidebarOpen: Bool
    let explainSelection: () -> Void
    let openSettings: ((@MainActor () -> Void)?) -> Void
    @Environment(\.requestPaperDeletion) private var requestPaperDeletion
    @State private var pageInput = "1"
    @FocusState private var pageFocused: Bool
    @State private var showWarnings = false
    @State private var penEnabled = false
    @State private var peekingAtOriginal = false
    @State private var mountedSourcePaperID: UUID?
    @State private var viewport = ReaderViewportClass(width: 900)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("PDFBilingualDisplayLayout") private var pdfLayout = PDFBilingualLayoutPreference.paragraph

    var body: some View {
        content
            .onGeometryChange(for: ReaderViewportClass.self) {
                ReaderViewportClass(width: $0.size.width)
            } action: { next in
                if viewport != next { viewport = next }
            }
            .sheet(item: $model.notePassageSheet) { sheet in
                NotePassageSheetView(model: model, sheet: sheet)
            }
    }

    private var content: some View {
        let summary = model.presentedDocumentSummary
        return VStack(spacing: 0) {
            header(compact: viewport.compactHeader)
            Divider()
            VStack(spacing: 0) {
                // A direct notebook entry only needs its editor. Once the reader has shown the
                // source, leave that same native canvas in place behind the notebook.
                if summary == nil || mountedSourcePaperID == model.selectedPaperID {
                    documentCanvas
                        .onChange(of: model.selectedPaperID, initial: true) { _, id in mountedSourcePaperID = id }
                    if !model.showingReflowLoading { readingBar(allowsSplit: viewport.allowsSplit) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(summary == nil)
            .accessibilityHidden(summary != nil)
            .overlay {
                ZStack {
                    if let summary {
                        DocumentSummaryPage(model: model, note: summary)
                            .id(summary.id)
                            .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 8)))
                    }
                }
                .animation(ReaderMotion.navigation(reduceMotion), value: summary != nil)
                .allowsHitTesting(summary != nil)
            }
        }
        .onChange(of: model.visiblePage) { _, page in
            if !pageFocused { pageInput = "\(page + 1)" }
            if model.pdfBilingual.isOpen { model.pdfBilingual.loadPage(model) }
        }
        .onChange(of: model.mode) { _, mode in
            if mode != "original" {
                model.pdfBilingual.close()
                if model.pdfNoteEditor != nil { model.closePDFReadingNote() }
            }
        }
        .onDisappear { model.pdfBilingual.close() }
        .onAppear { pageInput = "\(model.visiblePage + 1)" }
        .onChange(of: model.selectedPaperID) { _, _ in
            model.notePassageSheet = nil
            model.pdfBilingual.close()
            pageInput = "\(model.visiblePage + 1)"
        }
    }

    private var documentCanvas: some View {
        let reduceMotion = self.reduceMotion
        return ZStack {
            if model.usesHTMLReading {
                HTMLCanvas(model: model, sidebarOpen: sidebarOpen)
                    .transition(ReaderMotion.arrival())
            } else if model.showsPDFCanvas, isLocalPDF {
                PDFBilingualReadingView(
                    model: model, penEnabled: penEnabled, sidebarOpen: sidebarOpen,
                    openSettings: { openSettings(nil) },
                    layout: $pdfLayout, peekingAtOriginal: $peekingAtOriginal
                )
                .transition(ReaderMotion.arrival())
            } else if model.showsPDFCanvas {
                PDFCanvas(model: model, penEnabled: penEnabled).transition(ReaderMotion.arrival())
            }
            if model.showingReflowLoading {
                ReflowLoadingView(model: model).zIndex(1).transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(ReaderMotion.navigation(reduceMotion), value: model.usesHTMLReading)
        .animation(ReaderMotion.navigation(reduceMotion), value: model.showingReflowLoading)
        .keyframeAnimator(initialValue: CGFloat.zero, trigger: model.outlineArrival?.revision) { surface, offset in
            surface.offset(y: reduceMotion ? 0 : offset)
        } keyframes: { _ in
            if !reduceMotion, let arrival = model.outlineArrival {
                MoveKeyframe(arrival.forward ? 18 : -18)
                SpringKeyframe(0, duration: 0.29, spring: .smooth(duration: 0.29))
            } else {
                MoveKeyframe(0)
            }
        }
        .background(ReaderTheme.surface)
        .clipped()
        .overlay {
            GeometryReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    if let session = separatePDFNote {
                        PDFReadingNoteCard(model: model, session: session)
                            .frame(
                                width: min(350, max(1, proxy.size.width - 24)),
                                height: min(280, max(1, proxy.size.height - 24))
                            ).padding(12).transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .animation(ReaderMotion.disclosure(reduceMotion), value: separatePDFNote != nil)
            }
            .allowsHitTesting(separatePDFNote != nil)
        }
    }

    private var separatePDFNote: PDFNoteEditorSession? {
        guard model.presentedSummaryID == nil, model.mode == "original", let session = model.pdfNoteEditor,
            session.note.paperID == model.selectedPaperID, !session.usesReflowMargin
        else { return nil }
        return session
    }

    private var isLocalPDF: Bool { model.currentEdition?.usesSourceReflow == false }

    private func header(compact: Bool) -> some View {
        HStack(spacing: 12) {
            Button(action: model.returnFromReader) {
                Label("返回\(model.readerOrigin.title)", systemImage: "chevron.left")
            }
            .readerIconButtonStyle(.borderless).labelStyle(ReaderSymbolLabelStyle(iconOnly: true, motion: .left)).help(
                "返回\(model.readerOrigin.title)（⇧⌘L）"
            )
            .keyboardShortcut("l", modifiers: [.command, .shift])
            Text(model.paper?.displayTitle ?? "").font(ReaderTheme.editorial(18, weight: .medium))
                .foregroundStyle(ReaderTheme.ink).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            ReaderModePicker(
                bilingual: Binding(
                    get: { model.pdfBilingual.isOpen || model.mode != "original" },
                    set: { selected in setBilingualReading(selected) }))
            HStack(spacing: 2) {
                if let paper = model.currentEdition {
                    let favorite = model.workspace(for: paper.id).isFavorite
                    Button {
                        model.toggleFavorite(paper.id)
                    } label: {
                        ReaderIcon(.favorite, size: 17, filled: favorite)
                            .foregroundStyle(favorite ? ReaderTheme.accent : ReaderTheme.muted)
                            .readerIconTarget(macOS: 32)
                    }
                    .readerIconButtonStyle(.plain)
                    .accessibilityLabel(favorite ? "取消收藏" : "收藏论文")
                    .accessibilityAddTraits(favorite ? .isSelected : [])
                    .help(favorite ? "取消收藏" : "收藏论文")
                    readingStatusMenu(for: paper)
                }
            }
            .padding(.horizontal, 3)
            .readerGlassSurface(in: Capsule(), fallback: ReaderTheme.elevated)
        }
        .readerGlassGroup()
        .buttonStyle(.borderless).padding(.horizontal, compact ? 12 : 22).frame(height: 56)
        .background(ReaderTheme.canvas)
    }

    private func setBilingualReading(_ bilingual: Bool) {
        peekingAtOriginal = false
        if bilingual {
            model.closeDocumentSummary()
            if !model.openBilingualReading(translatingDocument: true) {
                openSettings {
                    model.closeDocumentSummary()
                    _ = model.openBilingualReading(translatingDocument: true)
                }
            }
        } else {
            model.showOriginalReading()
        }
    }

    private func readingStatusMenu(for paper: Paper) -> some View {
        let status = model.workspace(for: paper.id).status
        var items = PaperReadingStatus.allCases.map { choice in
            ReaderMenuItem.action(choice.title, selected: status == choice) {
                model.setReadingStatus(choice, for: paper.id)
            }
        }
        if let requestPaperDeletion {
            items.append(.divider)
            items.append(
                .action("删除论文…", icon: .delete, destructive: true) {
                    requestPaperDeletion(PaperDeletionRequest(paper, model: model))
                })
        }
        return ReaderPopupMenu("阅读状态与更多操作", items: items, width: 170) {
            ReaderActionGlyph(mark: .more, size: 17)
                .foregroundStyle(ReaderTheme.muted).readerIconTarget(macOS: 32)
        }
        .accessibilityValue(status.title).help("阅读状态与更多操作")
    }

    private func readingVersions(for paper: Paper) -> [ReaderMenuItem] {
        var items: [ReaderMenuItem] = []
        if !paper.previewPages.isEmpty {
            items.append(.action("旧版固定页", selected: model.mode == "reflow", run: model.openFixedPreview))
        }
        if !paper.readingPages.isEmpty {
            let title = paper.hasPublishedSourceReading ? "当前双语版" : "已保存的旧双语版"
            items.append(
                .action(title, selected: model.mode == "translated" && model.retainedReadingID == nil) {
                    model.openRetainedReading(nil)
                })
        }
        for (index, version) in (paper.retainedReadings ?? []).enumerated() {
            items.append(
                .action(
                    "保留版本 \(index + 1)", selected: model.mode == "translated" && model.retainedReadingID == version.id
                ) {
                    model.openRetainedReading(version.id)
                })
        }
        if paper.usesSourceReflow && !paper.readingPages.isEmpty {
            items.append(.divider)
            items.append(
                .action("重新生成双语版", enabled: !model.translating.contains(paper.id)) {
                    translate(regenerate: true)
                })
        }
        return items
    }

    @ViewBuilder private func editionControls(for paper: Paper) -> some View {
        let versions = readingVersions(for: paper)
        if !versions.isEmpty {
            ReaderPopupMenu("阅读版本", items: versions) {
                ReaderIcon(.source, size: 15).readerIconTarget()
            }.help("阅读版本")
        }
        if !paper.warnings.isEmpty {
            Button {
                showWarnings = true
            } label: {
                ReaderActionSymbol("info.circle").readerIconTarget()
            }.readerIconButtonStyle(.plain).accessibilityLabel("阅读提示").help("阅读提示")
                .popover(isPresented: $showWarnings) {
                    let warnings = Text(paper.warnings.joined(separator: "\n\n"))
                        .font(.callout).foregroundStyle(ReaderTheme.ink)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("阅读提示").font(ReaderTheme.editorial(16, weight: .semibold))
                        ViewThatFits(in: .vertical) {
                            warnings
                            ScrollView { warnings }
                        }
                    }
                    .padding(16).frame(width: 272, alignment: .leading).frame(maxHeight: 280)
                    .readerPopupSurface()
                }
        }
    }

    private func readingBar(allowsSplit: Bool) -> some View {
        let pageCount = model.displayedPageKeys.count
        let resolvedLayout = pdfLayout.resolved(allowsSplit: allowsSplit)
        let originalVisible = !model.pdfBilingual.isOpen || peekingAtOriginal || resolvedLayout == .split
        let continuousParagraphs =
            model.pdfBilingual.isOpen && resolvedLayout == .paragraph && !peekingAtOriginal
        return HStack(spacing: 12) {
            if pageCount == 0 {
                Text("等待正文就绪").font(.caption).foregroundStyle(ReaderTheme.muted)
            } else if model.usesHTMLReading {
                Text("\(model.visiblePage + 1) / \(pageCount) 段")
                    .font(.caption).foregroundStyle(ReaderTheme.muted)
            } else {
                if !continuousParagraphs {
                    Button {
                        model.navigateToPage(model.visiblePage - 1)
                    } label: {
                        ReaderActionSymbol("chevron.left")
                    }
                    .readerIconButtonStyle(.borderless).disabled(model.visiblePage <= 0).help("上一页").accessibilityLabel(
                        "上一页")
                }
                HStack(spacing: 4) {
                    TextField("页码", text: $pageInput).textFieldStyle(.plain).multilineTextAlignment(.center)
                        .frame(width: 28).focused($pageFocused).onSubmit(jumpToPage).accessibilityLabel("跳转页码")
                    Text("/ \(pageCount)").foregroundStyle(ReaderTheme.muted)
                }.font(.system(size: 11, design: .monospaced)).padding(.horizontal, 9).padding(.vertical, 5)
                    .readerGlassSurface(in: RoundedRectangle(cornerRadius: 6), bordered: true)
                    .help("输入原页页码并回车跳转")
                if !continuousParagraphs {
                    Button {
                        model.navigateToPage(model.visiblePage + 1)
                    } label: {
                        ReaderActionSymbol("chevron.right")
                    }
                    .readerIconButtonStyle(.borderless).disabled(model.visiblePage >= pageCount - 1).help("下一页")
                    .accessibilityLabel("下一页")
                }
            }
            if model.visiblePage == pageCount - 1, let summary = model.currentDocumentSummary {
                Button {
                    model.openReadingNote(summary)
                } label: {
                    DocumentSummaryLinkLabel()
                }.readerIconButtonStyle(.plain)
            }
            Button(action: model.toggleBookmark) {
                ReaderActionSymbol(model.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(model.isCurrentPageBookmarked ? ReaderTheme.accent : ReaderTheme.muted)
            }.readerIconButtonStyle(.borderless).disabled(pageCount == 0).help(
                model.isCurrentPageBookmarked ? "移除书签（⌘D）" : "添加书签（⌘D）"
            )
            .accessibilityLabel(model.isCurrentPageBookmarked ? "移除当前页书签" : "添加当前页书签")
            .keyboardShortcut("d")
            if let paper = model.currentEdition { editionControls(for: paper) }
            if model.pdfBilingual.isOpen && isLocalPDF && !peekingAtOriginal {
                PDFBilingualAppearanceMenu(layout: $pdfLayout, allowsSplit: allowsSplit)
            }
            Spacer()
            if model.pdfBilingual.isOpen && isLocalPDF && (model.selectionText.isEmpty || !originalVisible) {
                PDFTranslationStatusControl(model: model, layout: pdfLayout, openSettings: { openSettings(nil) })
            } else if model.mode == "translated", model.retainedReadingID == nil, let paper = model.currentEdition,
                paper.usesSourceReflow
            {
                if model.isReflowPlaying(paper.id) {
                    ProgressView().controlSize(.small)
                    ReflowPlaybackButton(running: true, action: model.pauseTranslation)
                } else if let job = paper.reflowJob, job.supportsContinuation && !job.finished {
                    if let reason = model.reflowFailure(for: paper) {
                        Text(reason).lineLimit(1).foregroundStyle(ReaderTheme.muted).help(reason)
                    }
                    ReflowPlaybackButton(running: false) { translate() }
                        .disabled(model.translating.contains(paper.id))
                }
            }
            if !model.selectionText.isEmpty && originalVisible {
                if isLocalPDF && model.mode == "original" {
                    Button {
                        model.pdfBilingual.translateSelection(model)
                    } label: {
                        Label("翻译选区", systemImage: "character.bubble").labelStyle(ReaderSymbolLabelStyle())
                    }
                    .readerIconButtonStyle(.borderless).disabled(
                        model.pdfSelectionSpansPages || model.pdfBilingual.isTranslating
                    )
                    .help(model.pdfSelectionSpansPages ? "跨页选文请逐页翻译" : "只发送所选文字")
                }
                if !model.usesHTMLReading {
                    Button(action: model.highlightSelection) {
                        Label("高亮", systemImage: "highlighter").labelStyle(ReaderSymbolLabelStyle(motion: .write))
                    }.readerIconButtonStyle(.borderless)
                }
            }
            if model.hasPDFNoteSelection {
                Button {
                    Task { await model.beginPDFReadingNote() }
                } label: {
                    Label("添加笔记", readerIcon: .annotation).labelStyle(.iconOnly).readerIconTarget()
                }.readerIconButtonStyle(.borderless).help("添加笔记").accessibilityLabel("添加笔记")
                    .quickStartTarget(.annotation)
            }
            if !model.assistantSelectionText.isEmpty {
                Button(action: explainSelection) {
                    Label("解释选文", readerIcon: .discussion).labelStyle(.iconOnly).readerIconTarget()
                }.readerIconButtonStyle(.borderless).help("解释选文").accessibilityLabel("解释选文")
            }
            #if os(iOS)
                if !model.usesHTMLReading && originalVisible {
                    Toggle(isOn: $penEnabled) { ReaderActionSymbol("pencil.tip.crop.circle") }
                        .readerIconButtonStyle(.borderless).toggleStyle(.button).accessibilityLabel("手写批注")
                }
            #endif
        }.buttonStyle(.borderless).font(.caption).padding(.horizontal, 22).frame(minHeight: 42)
            .background(ReaderTheme.canvas)
            .overlay(alignment: .top) { Rectangle().fill(ReaderTheme.line).frame(height: 0.5) }
    }

    private func jumpToPage() {
        guard let page = Int(pageInput), page > 0, page <= model.displayedPageKeys.count else {
            pageInput = "\(model.visiblePage + 1)"
            return
        }
        model.navigateToPage(page - 1)
        pageFocused = false
    }

    private func translate(regenerate: Bool = false) {
        if model.isModelReadyForRequests {
            model.startAIReflow(regenerate: regenerate)
        } else {
            openSettings {
                model.startAIReflow(regenerate: regenerate)
            }
        }
    }
}

private struct ReaderViewportClass: Equatable {
    let compactHeader: Bool
    let allowsSplit: Bool

    init(width: CGFloat) {
        compactHeader = width < 520
        allowsSplit = width >= 570
    }
}
