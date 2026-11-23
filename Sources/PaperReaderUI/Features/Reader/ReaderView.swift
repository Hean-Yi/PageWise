import PaperReaderKit
import SwiftUI

struct ReaderView: View {
    @Bindable var model: ReaderModel
    @Binding var libraryAgentPresented: Bool
    let openSettings: () -> Void
    @State private var showAssistant = false
    @State private var assistantTab = "chat"
    @State private var pageInput = "1"
    @FocusState private var pageFocused: Bool
    @State private var showAssistantSheet = false
    @State private var pendingSettings = false
    @State private var pendingNoteSave = false
    @State private var showWarnings = false
    @State private var penEnabled = false
    @State private var peekingAtOriginal = false
    @AppStorage("PDFBilingualDisplayLayout") private var pdfLayout = PDFBilingualLayoutPreference.paragraph
    @State private var askSave = false
    @State private var question = ""

    var body: some View {
        GeometryReader { proxy in content(width: proxy.size.width) }
            .sheet(
                isPresented: $showAssistantSheet,
                onDismiss: {
                    if pendingSettings {
                        pendingSettings = false
                        openSettings()
                    } else if pendingNoteSave {
                        pendingNoteSave = false
                        askSave = true
                    }
                }, content: { assistant.frame(minWidth: 300, minHeight: 400) })
    }

    private func content(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            header(width: width)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ZStack {
                        if model.usesHTMLReading {
                            HTMLCanvas(
                                model: model,
                                sidebarOpen: (showAssistant && !libraryAgentPresented && width >= 900)
                                    || showAssistantSheet)
                        } else if model.showsPDFCanvas, isLocalPDF {
                            PDFBilingualReadingView(
                                model: model, penEnabled: penEnabled, openSettings: requestSettings,
                                layout: $pdfLayout, peekingAtOriginal: $peekingAtOriginal)
                        } else if model.showsPDFCanvas {
                            PDFCanvas(model: model, penEnabled: penEnabled)
                        }
                        if model.showingReflowLoading {
                            ReflowLoadingView(model: model)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !model.showingReflowLoading { readingBar(width: width) }
                }
                if showAssistant && !model.pdfBilingual.isOpen && !libraryAgentPresented && width >= 900 {
                    Divider()
                    assistant.frame(width: 312)
                }
            }
        }
        .confirmationDialog("将本次讨论整理到笔记？", isPresented: $askSave, titleVisibility: .visible) {
            Button("包含讨论，保存笔记") { Task { await model.saveToObsidian(includeDiscussion: true) } }
            Button("不包含讨论，保存笔记") { Task { await model.saveToObsidian(includeDiscussion: false) } }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: model.visiblePage) { _, page in
            if !pageFocused { pageInput = "\(page + 1)" }
            if model.pdfBilingual.isOpen { model.pdfBilingual.loadPage(model) }
        }
        .onChange(of: model.mode) { _, mode in
            if mode != "original" { model.pdfBilingual.close() }
        }
        .onDisappear { model.pdfBilingual.close() }
        .onAppear {
            pageInput = "\(model.visiblePage + 1)"
            if libraryAgentPresented { showAssistant = false }
        }
        .onChange(of: libraryAgentPresented) { _, presented in
            if presented {
                showAssistant = false
                showAssistantSheet = false
            }
        }
        .onChange(of: model.selectedPaperID) { _, _ in
            model.pdfBilingual.close()
            question = ""
            pageInput = "\(model.visiblePage + 1)"
        }
    }

    private var displayedChats: [ChatTurn] {
        model.currentChats + (model.assistantDraft.flatMap { $0.paperID == model.selectedPaperID ? [$0] : nil } ?? [])
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
            Button {
                toggleAssistant(width: width)
            } label: {
                Label("助读与笔记", systemImage: "sidebar.right")
            }.labelStyle(.iconOnly).help("助读与笔记")
                .foregroundStyle(
                    (showAssistant && !libraryAgentPresented && width >= 900) || showAssistantSheet
                        ? ReaderTheme.accent : ReaderTheme.muted)
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
            if !model.openBilingualReading(translatingDocument: pdfLayout == .paragraph) { requestSettings() }
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
                PDFTranslationStatusControl(model: model, layout: pdfLayout, openSettings: requestSettings)
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
                Button {
                    libraryAgentPresented = false
                    assistantTab = "chat"
                    if width < 900 || model.pdfBilingual.isOpen {
                        showAssistantSheet = true
                    } else {
                        showAssistant = true
                    }
                    question = "请结合全文解释选中内容。"
                } label: {
                    Label("解释", systemImage: "sparkles")
                }
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

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("阅读工具", selection: $assistantTab) {
                    Label("助读", systemImage: "sparkles").tag("chat")
                    Label("笔记", systemImage: "square.and.pencil").tag("notes")
                }.pickerStyle(.segmented).labelsHidden()
                Spacer(minLength: 10)
                if model.busyAI { ProgressView().controlSize(.small) }
                Button {
                    showAssistant = false
                    showAssistantSheet = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(ReaderTheme.muted)
                .help("关闭助读与笔记").accessibilityLabel("关闭助读与笔记")
            }.padding(.horizontal, 16).padding(.vertical, 18)
            Divider()
            if assistantTab == "notes" {
                ReaderNotesView(
                    model: model,
                    summarize: {
                        if configured { Task { await model.summarize() } } else { requestSettings() }
                    }, saveNote: requestNoteSave, didNavigate: { showAssistantSheet = false })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if displayedChats.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("问这篇论文").font(ReaderTheme.editorial(26))
                                    .foregroundStyle(ReaderTheme.ink).padding(.top, 12)
                                VStack(spacing: 0) {
                                    prompt("核心贡献", icon: "lightbulb", question: "这篇论文主要解决什么问题，有哪些核心贡献？")
                                    prompt(
                                        "方法思路", icon: "point.3.connected.trianglepath.dotted",
                                        question: "这篇论文的方法是如何工作的？")
                                    prompt("局限与不足", icon: "scope", question: "这项方法有哪些局限？")
                                }
                            }
                        }
                        ForEach(displayedChats) { turn in
                            VStack(alignment: .leading, spacing: 14) {
                                Text(turn.question).font(.callout.weight(.medium)).padding(12).frame(
                                    maxWidth: .infinity, alignment: .leading
                                )
                                .background(ReaderTheme.elevated, in: RoundedRectangle(cornerRadius: 12))
                                Text(turn.answer).font(.callout).textSelection(.enabled).lineSpacing(5)
                                DisclosureGroup("来源 · \(turn.evidence.count)") {
                                    ForEach(turn.evidence) { source in
                                        Button {
                                            model.jump(to: source)
                                        } label: {
                                            Text(
                                                "[\(source.id)] \(source.title)\(source.sourcePage.map { " · p.\($0 + 1)" } ?? "")"
                                            )
                                            .font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                                        }.buttonStyle(.plain).padding(.vertical, 5)
                                    }
                                }.font(.caption).foregroundStyle(ReaderTheme.muted)
                            }
                        }
                    }.padding(20)
                }
                composer
            }
        }.background(ReaderTheme.canvas)
    }

    private func prompt(_ title: String, icon: String, question value: String) -> some View {
        AssistantSuggestion(title: title, systemImage: icon) { question = value }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.selectionText.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Rectangle().fill(ReaderTheme.accent).frame(width: 2)
                    Text(model.selectionText).font(.caption).foregroundStyle(ReaderTheme.muted).lineLimit(3)
                    Button {
                        model.selectionText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(ReaderTheme.muted).accessibilityLabel("移除选文")
                }.fixedSize(horizontal: false, vertical: true)
            }
            TextField("问这篇论文…", text: $question, axis: .vertical).lineLimit(2...6).textFieldStyle(.plain).font(.callout)
            HStack {
                Button(action: requestSettings) {
                    Label(
                        model.modelSettings.model.isEmpty ? "配置模型" : model.modelSettings.model,
                        systemImage: "slider.horizontal.3"
                    ).font(.system(size: 10)).lineLimit(1)
                }.buttonStyle(.plain).foregroundStyle(ReaderTheme.muted).help("模型设置")
                Spacer()
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ReaderTheme.surface).frame(width: 30, height: 30)
                        .background(ReaderTheme.ink, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("发送问题")
                    .opacity(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busyAI)
            }
        }.padding(16).background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ReaderTheme.line)).padding(14)
    }

    private var configured: Bool {
        (try? model.modelSettings.normalized()) != nil
    }
    private func translate(regenerate: Bool = false) {
        if (try? model.translationSettings.normalized()) != nil {
            model.startAIReflow(regenerate: regenerate)
        } else {
            requestSettings()
        }
    }
    private func send() {
        guard configured else {
            requestSettings()
            return
        }
        let text = question
        question = ""
        Task { await model.ask(text) }
    }
    private func toggleAssistant(width: CGFloat) {
        libraryAgentPresented = false
        if width < 900 || model.pdfBilingual.isOpen { showAssistantSheet = true } else { showAssistant.toggle() }
    }
    private func requestSettings() {
        if showAssistantSheet {
            pendingSettings = true
            showAssistantSheet = false
        } else {
            openSettings()
        }
    }

    private func requestNoteSave() {
        if showAssistantSheet {
            pendingNoteSave = true
            showAssistantSheet = false
        } else {
            askSave = true
        }
    }
}
