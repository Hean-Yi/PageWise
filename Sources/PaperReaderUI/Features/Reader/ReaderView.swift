import PaperReaderKit
import SwiftUI

struct ReaderView: View {
    @Bindable var model: ReaderModel
    let sidebarOpen: Bool
    let explainSelection: () -> Void
    let requestNoteSave: () -> Void
    let openSettings: () -> Void
    @State private var pageInput = "1"
    @FocusState private var pageFocused: Bool
    @State private var showWarnings = false
    @State private var penEnabled = false
    @State private var peekingAtOriginal = false
    @AppStorage("PDFBilingualDisplayLayout") private var pdfLayout = PDFBilingualLayoutPreference.paragraph

    var body: some View {
        GeometryReader { proxy in content(width: proxy.size.width) }
    }

    private func content(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            header(width: width)
            Divider()
            ZStack {
                if model.usesHTMLReading {
                    HTMLCanvas(model: model, sidebarOpen: sidebarOpen)
                } else if model.showsPDFCanvas, isLocalPDF {
                    PDFBilingualReadingView(
                        model: model, penEnabled: penEnabled, openSettings: openSettings,
                        layout: $pdfLayout, peekingAtOriginal: $peekingAtOriginal)
                } else if model.showsPDFCanvas {
                    PDFCanvas(model: model, penEnabled: penEnabled)
                }
                if model.showingReflowLoading { ReflowLoadingView(model: model) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !model.showingReflowLoading { readingBar(width: width) }
        }
        .onChange(of: model.visiblePage) { _, page in
            if !pageFocused { pageInput = "\(page + 1)" }
            if model.pdfBilingual.isOpen { model.pdfBilingual.loadPage(model) }
        }
        .onChange(of: model.mode) { _, mode in
            if mode != "original" { model.pdfBilingual.close() }
        }
        .onDisappear { model.pdfBilingual.close() }
        .onAppear { pageInput = "\(model.visiblePage + 1)" }
        .onChange(of: model.selectedPaperID) { _, _ in
            model.pdfBilingual.close()
            pageInput = "\(model.visiblePage + 1)"
        }
    }

    private var isLocalPDF: Bool { model.currentEdition?.usesSourceReflow == false }

    private func header(width: CGFloat) -> some View {
        HStack(spacing: 12) {
            Button {
                model.select(nil)
            } label: {
                Label("返回书库", systemImage: "chevron.left")
            }
            .labelStyle(.iconOnly).help("返回书库").keyboardShortcut("l", modifiers: [.command, .shift])
            Text(model.paper?.title ?? "").font(ReaderTheme.editorial(18, weight: .medium))
                .foregroundStyle(ReaderTheme.ink).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Picker(
                "阅读模式",
                selection: Binding(
                    get: { model.pdfBilingual.isOpen || model.mode != "original" },
                    set: { selected in setBilingualReading(selected) }
                )
            ) {
                Text("原版").tag(false)
                Text("双语重排").tag(true)
            }.pickerStyle(.segmented).controlSize(.regular).labelsHidden().fixedSize().accessibilityLabel("阅读模式")
            readingMenu(width: width)
        }
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
            if !model.openBilingualReading(translatingDocument: pdfLayout == .paragraph) { openSettings() }
        } else {
            model.pdfBilingual.close()
            if model.mode != "original" {
                model.changeMode(to: "original")
                if model.mode != "original" { model.readOriginal() }
            }
        }
    }

    private func readingMenu(width: CGFloat) -> some View {
        Menu {
            if isLocalPDF && model.pdfBilingual.isOpen {
                PDFBilingualMenuItems(
                    model: model, layout: $pdfLayout, peekingAtOriginal: $peekingAtOriginal, width: width)
                Divider()
            }
            if let paper = model.currentEdition {
                let workspace = model.workspace(for: paper.id)
                Button {
                    model.toggleFavorite(paper.id)
                } label: {
                    Label(
                        workspace.isFavorite ? "取消收藏" : "收藏论文", systemImage: workspace.isFavorite ? "star.fill" : "star"
                    )
                }
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
                Button(action: requestNoteSave) { Label("保存到 Obsidian", systemImage: "square.and.arrow.up") }
                if !paper.warnings.isEmpty {
                    Button {
                        showWarnings = true
                    } label: {
                        Label("阅读提示", systemImage: "info.circle")
                    }
                }
                let olderVersions = paper.retainedReadings ?? []
                let hasLegacyEdition = !paper.readingPages.isEmpty && !paper.hasPublishedSourceReading
                if !paper.previewPages.isEmpty || !olderVersions.isEmpty || hasLegacyEdition {
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
                    }
                }
                if paper.usesSourceReflow, !paper.readingPages.isEmpty {
                    Button("重新生成双语版") { translate(regenerate: true) }
                        .disabled(model.translating.contains(paper.id))
                }
            }
        } label: {
            Label("更多阅读选项", systemImage: "ellipsis.circle")
        }.labelStyle(.iconOnly).fixedSize().help("更多阅读选项")
    }

    private func readingBar(width: CGFloat) -> some View {
        let originalVisible = !model.pdfBilingual.isOpen || peekingAtOriginal || pdfLayout.resolved(at: width) == .split
        let continuousParagraphs = model.pdfBilingual.isOpen && pdfLayout == .paragraph && !peekingAtOriginal
        return HStack(spacing: 12) {
            if model.pageKeys.isEmpty {
                Text("等待正文就绪").font(.caption).foregroundStyle(ReaderTheme.muted)
            } else if model.usesHTMLReading {
                Text("\(model.visiblePage + 1) / \(model.pageKeys.count) 段")
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
                    Text("/ \(model.pageKeys.count)").foregroundStyle(ReaderTheme.muted)
                }.font(.system(size: 11, design: .monospaced)).padding(.horizontal, 9).padding(.vertical, 5)
                    .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ReaderTheme.line))
                    .help("输入原页页码并回车跳转")
                if !continuousParagraphs {
                    Button {
                        model.navigateToPage(model.visiblePage + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(model.visiblePage >= model.pageKeys.count - 1).help("下一页").accessibilityLabel("下一页")
                }
            }
            Button(action: model.toggleBookmark) {
                Image(systemName: model.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(model.isCurrentPageBookmarked ? ReaderTheme.accent : ReaderTheme.muted)
            }.disabled(model.pageKeys.isEmpty).help(model.isCurrentPageBookmarked ? "移除书签" : "添加书签")
                .accessibilityLabel(model.isCurrentPageBookmarked ? "移除当前页书签" : "添加当前页书签")
                .keyboardShortcut("d")
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
            if !model.assistantSelectionText.isEmpty {
                Button(action: explainSelection) {
                    Label("解释选文", systemImage: "text.bubble")
                        .labelStyle(.iconOnly)
                }.help("解释选文").accessibilityLabel("解释选文")
            }
            #if os(iOS)
                if !model.usesHTMLReading && originalVisible {
                    Toggle(isOn: $penEnabled) { Image(systemName: "pencil.tip.crop.circle") }
                        .toggleStyle(.button).accessibilityLabel("手写批注")
                }
            #endif
        }.buttonStyle(.borderless).font(.caption).padding(.horizontal, 22).frame(height: 42)
            .background(ReaderTheme.canvas)
            .overlay(alignment: .top) { Rectangle().fill(ReaderTheme.line).frame(height: 0.5) }
    }

    private func jumpToPage() {
        guard let page = Int(pageInput), page > 0, page <= model.pageKeys.count else {
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
