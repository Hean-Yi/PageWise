import PaperReaderKit
import SwiftUI

struct ReaderView: View {
    @Bindable var model: ReaderModel
    let sidebarOpen: Bool
    let explainSelection: () -> Void
    let openSettings: () -> Void
    @State private var pageInput = "1"
    @FocusState private var pageFocused: Bool
    @State private var showWarnings = false
    @State private var penEnabled = false
    @State private var peekingAtOriginal = false
    @State private var mountedSourcePaperID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("PDFBilingualDisplayLayout") private var pdfLayout = PDFBilingualLayoutPreference.paragraph

    var body: some View {
        GeometryReader { proxy in content(width: proxy.size.width) }
            .sheet(item: $model.notePassageSheet) { sheet in
                NotePassageSheetView(model: model, sheet: sheet)
            }
    }

    private func content(width: CGFloat) -> some View {
        let summary = model.presentedDocumentSummary
        return VStack(spacing: 0) {
            header(width: width)
            Divider()
            VStack(spacing: 0) {
                // A direct notebook entry only needs its editor. Once the reader has shown the
                // source, leave that same native canvas in place behind the notebook.
                if summary == nil || mountedSourcePaperID == model.selectedPaperID {
                    documentCanvas
                        .onChange(of: model.selectedPaperID, initial: true) { _, id in mountedSourcePaperID = id }
                    if !model.showingReflowLoading { readingBar(width: width) }
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
                    model: model, penEnabled: penEnabled, openSettings: openSettings,
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
                    if model.presentedSummaryID == nil, model.mode == "original", let session = model.pdfNoteEditor,
                        session.note.paperID == model.selectedPaperID
                    {
                        PDFReadingNoteCard(model: model, session: session)
                            .frame(
                                width: min(350, max(1, proxy.size.width - 24)),
                                height: min(280, max(1, proxy.size.height - 24))
                            ).padding(12).transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .animation(ReaderMotion.disclosure(reduceMotion), value: model.pdfNoteEditor != nil)
            }
            .allowsHitTesting(model.pdfNoteEditor != nil)
        }
    }

    private var isLocalPDF: Bool { model.currentEdition?.usesSourceReflow == false }

    private func header(width: CGFloat) -> some View {
        HStack(spacing: 12) {
            Button(action: model.returnFromReader) {
                Label("返回\(model.readerOrigin.title)", systemImage: "chevron.left")
            }
            .labelStyle(.iconOnly).help("返回\(model.readerOrigin.title)")
            .keyboardShortcut("l", modifiers: [.command, .shift])
            Text(model.paper?.title ?? "").font(ReaderTheme.editorial(18, weight: .medium))
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
                            .contentTransition(.opacity)
                            .animation(ReaderMotion.feedback(reduceMotion), value: favorite)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(favorite ? "取消收藏" : "收藏论文")
                    .accessibilityAddTraits(favorite ? .isSelected : [])
                    .help(favorite ? "取消收藏" : "收藏论文")
                }
                readingMenu
            }
            .padding(.horizontal, 3)
            .readerGlassSurface(in: Capsule(), fallback: ReaderTheme.elevated)
        }
        .readerGlassGroup()
        .buttonStyle(.borderless).padding(.horizontal, width < 520 ? 12 : 22).frame(height: 56)
        .background(ReaderTheme.canvas)
        .alert("阅读提示", isPresented: $showWarnings) {
            Button("好") {}
        } message: {
            Text(model.paper?.warnings.joined(separator: "\n") ?? "")
        }
    }

    private func setBilingualReading(_ bilingual: Bool) {
        peekingAtOriginal = false
        if bilingual {
            model.closeDocumentSummary()
            if !model.openBilingualReading(translatingDocument: pdfLayout == .paragraph) { openSettings() }
        } else {
            model.showOriginalReading()
        }
    }

    private var readingMenu: some View {
        Menu {
            if let paper = model.currentEdition {
                let workspace = model.workspace(for: paper.id)
                Menu("阅读状态") {
                    Picker(
                        "阅读状态",
                        selection: Binding(
                            get: { workspace.status }, set: { model.setReadingStatus($0, for: paper.id) })
                    ) {
                        ForEach([PaperReadingStatus.unread, .reading, .finished], id: \.self) { status in
                            Text(status.title).tag(status)
                        }
                    }.pickerStyle(.inline).labelsHidden()
                }
                if !paper.warnings.isEmpty {
                    Button("阅读提示") { showWarnings = true }
                }
                let olderVersions = paper.retainedReadings ?? []
                let hasLegacyEdition = !paper.readingPages.isEmpty && !paper.hasPublishedSourceReading
                let canRegenerate = paper.usesSourceReflow && !paper.readingPages.isEmpty
                if !paper.previewPages.isEmpty || !olderVersions.isEmpty || hasLegacyEdition || canRegenerate {
                    Menu("阅读版本") {
                        if !paper.previewPages.isEmpty {
                            Button("旧版固定页", action: model.openFixedPreview)
                        }
                        if !paper.readingPages.isEmpty {
                            Button(hasLegacyEdition ? "已保存的旧双语版" : "当前双语版") { model.openRetainedReading(nil) }
                        }
                        ForEach(Array(olderVersions.enumerated()), id: \.element.id) { index, version in
                            Button("保留版本 \(index + 1)") { model.openRetainedReading(version.id) }
                        }
                        if canRegenerate {
                            Divider()
                            Button("重新生成双语版") { translate(regenerate: true) }
                                .disabled(model.translating.contains(paper.id))
                        }
                    }
                }
                Divider()
                DeletePaperButton(paper: paper, model: model)
            }
        } label: {
            Image(systemName: "ellipsis").font(.body.weight(.semibold))
                .frame(minWidth: 32, minHeight: 32).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("更多阅读选项").help("更多阅读选项")
    }

    private func readingBar(width: CGFloat) -> some View {
        let pageCount = model.displayedPageKeys.count
        let originalVisible = !model.pdfBilingual.isOpen || peekingAtOriginal || pdfLayout.resolved(at: width) == .split
        let continuousParagraphs = model.pdfBilingual.isOpen && pdfLayout == .paragraph && !peekingAtOriginal
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
                        Image(systemName: "chevron.left")
                    }
                    .disabled(model.visiblePage <= 0).help("上一页").accessibilityLabel("上一页")
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
                        Image(systemName: "chevron.right")
                    }
                    .disabled(model.visiblePage >= pageCount - 1).help("下一页").accessibilityLabel("下一页")
                }
            }
            if model.visiblePage == pageCount - 1, let summary = model.currentDocumentSummary {
                Button {
                    model.openReadingNote(summary)
                } label: {
                    Label("文末总结", readerIcon: .notebook).labelStyle(.titleAndIcon)
                }
            }
            Button(action: model.toggleBookmark) {
                Image(systemName: model.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(model.isCurrentPageBookmarked ? ReaderTheme.accent : ReaderTheme.muted)
            }.disabled(pageCount == 0).help(model.isCurrentPageBookmarked ? "移除书签" : "添加书签")
                .accessibilityLabel(model.isCurrentPageBookmarked ? "移除当前页书签" : "添加当前页书签")
                .keyboardShortcut("d")
            if model.pdfBilingual.isOpen && isLocalPDF && !peekingAtOriginal {
                PDFBilingualAppearanceMenu(model: model, layout: $pdfLayout, width: width)
            }
            Spacer()
            if model.pdfBilingual.isOpen && isLocalPDF && (model.selectionText.isEmpty || !originalVisible) {
                PDFTranslationStatusControl(model: model, layout: pdfLayout, openSettings: openSettings)
            } else if model.mode == "translated", model.retainedReadingID == nil, let paper = model.currentEdition,
                paper.usesSourceReflow
            {
                if model.translating.contains(paper.id) {
                    ProgressView().controlSize(.small)
                    Button("暂停生成", action: model.pauseTranslation)
                } else if let job = paper.reflowJob, job.supportsContinuation && !job.finished {
                    if let reason = job.failure {
                        Text(reason).lineLimit(1).foregroundStyle(ReaderTheme.muted).help(reason)
                    }
                    Button("继续生成") { translate() }
                }
            }
            if !model.selectionText.isEmpty && originalVisible {
                if isLocalPDF && model.mode == "original" {
                    Button {
                        model.pdfBilingual.translateSelection(model)
                    } label: {
                        Label("翻译选区", systemImage: "character.bubble")
                    }
                    .disabled(model.pdfSelectionSpansPages || model.pdfBilingual.isTranslating)
                    .help(model.pdfSelectionSpansPages ? "跨页选文请逐页翻译" : "只发送所选文字")
                }
                if !model.usesHTMLReading {
                    Button(action: model.highlightSelection) { Label("高亮", systemImage: "highlighter") }
                }
            }
            if model.hasPDFNoteSelection {
                Button {
                    Task { await model.beginPDFReadingNote() }
                } label: {
                    Label("添加笔记", readerIcon: .annotation).labelStyle(.iconOnly).readerIconTarget()
                }.help("添加笔记").accessibilityLabel("添加笔记")
                    .quickStartTarget(.annotation)
            }
            if !model.assistantSelectionText.isEmpty {
                Button(action: explainSelection) {
                    Label("解释选文", readerIcon: .discussion).labelStyle(.iconOnly).readerIconTarget()
                }.help("解释选文").accessibilityLabel("解释选文")
            }
            #if os(iOS)
                if !model.usesHTMLReading && originalVisible {
                    Toggle(isOn: $penEnabled) { Image(systemName: "pencil.tip.crop.circle") }
                        .toggleStyle(.button).accessibilityLabel("手写批注")
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
        if (try? model.modelSettings.normalized()) != nil {
            model.startAIReflow(regenerate: regenerate)
        } else {
            openSettings()
        }
    }
}
