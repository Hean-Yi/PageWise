import PaperReaderKit
import SwiftUI

struct ReaderView: View {
    @Bindable var model: ReaderModel
    @Binding var libraryAgentPresented: Bool
    let openSettings: () -> Void
    @State private var showAssistant = true
    @State private var assistantTab = "chat"
    @State private var pageInput = "1"
    @FocusState private var pageFocused: Bool
    @State private var showAssistantSheet = false
    @State private var pendingSettings = false
    @State private var pendingNoteSave = false
    @State private var showWarnings = false
    @State private var penEnabled = false
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
            VStack(spacing: 12) {
                if width < 760 {
                    title
                    controls(width: width)
                } else {
                    HStack(spacing: 24) {
                        title
                        controls(width: width)
                    }
                }
            }.padding(.horizontal, 22).padding(.vertical, 14).background(ReaderTheme.canvas)
            if model.paper?.canReflow == false {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").foregroundStyle(ReaderTheme.muted)
                    Text("原始 PDF").fontWeight(.medium)
                    Text("· 暂不支持此文档重排").foregroundStyle(ReaderTheme.muted)
                    Spacer()
                    Button {
                        showWarnings = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain).help("查看原因")
                    .popover(isPresented: $showWarnings) {
                        Text(model.paper?.warnings.joined(separator: "\n") ?? "")
                            .font(.callout).padding(20).frame(maxWidth: 360)
                    }
                }.font(.caption).padding(.horizontal, 24).padding(.vertical, 10).background(.orange.opacity(0.06))
            }
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Group {
                        if model.mode == "translated" && model.activePages.isEmpty && model.paper?.canReflow == true {
                            VStack(spacing: 20) {
                                Image(systemName: "character.book.closed").font(.system(size: 42, weight: .ultraLight))
                                    .foregroundStyle(ReaderTheme.accent)
                                Text("用熟悉的语言阅读").font(.system(.title2, design: .serif))
                                Button("开始翻译", action: translate).buttonStyle(.borderedProminent).controlSize(.large)
                                    .disabled(model.translating.contains(model.selectedPaperID ?? UUID()))
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            PDFCanvas(model: model, penEnabled: penEnabled).frame(maxWidth: 820)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    readingBar(width: width)
                }
                if showAssistant && !libraryAgentPresented && width >= 900 {
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
        .onChange(of: model.visiblePage) { _, page in if !pageFocused { pageInput = "\(page + 1)" } }
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
            question = ""
            pageInput = "\(model.visiblePage + 1)"
        }
    }

    private var title: some View {
        HStack(spacing: 14) {
            Button {
                model.select(nil)
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(ReaderTheme.muted).help("返回书库").accessibilityLabel("返回书库")
            VStack(alignment: .leading, spacing: 5) {
                Text(model.paper?.title ?? "").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if let paper = model.paper {
                    Menu {
                        ForEach([PaperReadingStatus.unread, .reading, .finished], id: \.self) { status in
                            Button(status.title) { model.setReadingStatus(status, for: paper.id) }
                        }
                    } label: {
                        Text(model.workspace(for: paper.id).status.title).font(.system(size: 10))
                            .foregroundStyle(ReaderTheme.muted)
                    }.menuStyle(.borderlessButton).fixedSize().help("阅读状态")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func controls(width: CGFloat) -> some View {
        HStack(spacing: 14) {
            if model.paper?.canReflow == true {
                Picker("阅读模式", selection: Binding(get: { model.mode }, set: { model.changeMode(to: $0) })) {
                    Text("原文").tag("original")
                    Text("重排").tag("reflow")
                    Text("双语").tag("translated")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 186)
            }
            if model.translating.contains(model.selectedPaperID ?? UUID()) {
                Button(action: model.pauseTranslation) { Image(systemName: "pause.circle") }
                    .help("暂停翻译").accessibilityLabel("暂停翻译")
            } else if model.paper?.canReflow == true {
                Button(action: translate) { Label("翻译", systemImage: "translate") }
                    .help("翻译 / 继续")
            }
            Spacer(minLength: 0).frame(maxWidth: width < 760 ? .infinity : 0)
            Button {
                requestNoteSave()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("保存到 Obsidian").accessibilityLabel("保存到 Obsidian")
            Button {
                toggleAssistant(width: width)
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(showAssistant || showAssistantSheet ? ReaderTheme.accent : ReaderTheme.muted)
            }.help("助读与笔记").accessibilityLabel("助读与笔记")
        }.buttonStyle(.borderless).font(.system(size: 14))
    }

    private func readingBar(width: CGFloat) -> some View {
        HStack(spacing: 12) {
            Button {
                model.navigateToPage(model.visiblePage - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(model.visiblePage <= 0).help("上一页").accessibilityLabel("上一页")
            HStack(spacing: 4) {
                TextField("页码", text: $pageInput).textFieldStyle(.plain).multilineTextAlignment(.center)
                    .frame(width: 28).focused($pageFocused).onSubmit(jumpToPage).accessibilityLabel("跳转页码")
                Text("/ \(model.pageKeys.count)").foregroundStyle(ReaderTheme.muted)
            }.font(.system(size: 11, design: .monospaced)).padding(.horizontal, 9).padding(.vertical, 5)
                .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ReaderTheme.line))
            Button {
                model.navigateToPage(model.visiblePage + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(model.visiblePage >= model.pageKeys.count - 1).help("下一页").accessibilityLabel("下一页")
            Button(action: model.toggleBookmark) {
                Image(systemName: model.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(model.isCurrentPageBookmarked ? ReaderTheme.accent : ReaderTheme.muted)
            }.disabled(model.pageKeys.isEmpty).help(model.isCurrentPageBookmarked ? "移除书签" : "添加书签")
                .accessibilityLabel(model.isCurrentPageBookmarked ? "移除当前页书签" : "添加当前页书签")
                .keyboardShortcut("d")
            Spacer()
            if !model.selectionText.isEmpty {
                Button(action: model.highlightSelection) { Label("高亮", systemImage: "highlighter") }
                Button {
                    libraryAgentPresented = false
                    assistantTab = "chat"
                    if width < 900 { showAssistantSheet = true } else { showAssistant = true }
                    question = "请结合全文解释选中内容。"
                } label: {
                    Label("解释", systemImage: "sparkles")
                }
            }
            #if os(iOS)
                Toggle(isOn: $penEnabled) { Image(systemName: "pencil.tip.crop.circle") }
                    .toggleStyle(.button).accessibilityLabel("手写批注")
            #endif
        }.buttonStyle(.borderless).font(.caption).padding(.horizontal, 22).frame(height: 46)
            .background(ReaderTheme.canvas)
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
                        if model.currentChats.isEmpty {
                            VStack(alignment: .leading, spacing: 20) {
                                Image(systemName: "sparkles").font(.system(size: 26, weight: .light)).foregroundStyle(
                                    ReaderTheme.accent
                                )
                                .padding(.top, 16)
                                Text("从一个问题开始").font(.system(size: 20, weight: .medium, design: .serif))
                                VStack(spacing: 8) {
                                    prompt("核心贡献", icon: "lightbulb", question: "这篇论文主要解决什么问题，有哪些核心贡献？")
                                    prompt(
                                        "方法思路", icon: "point.3.connected.trianglepath.dotted",
                                        question: "这篇论文的方法是如何工作的？")
                                    prompt("局限与不足", icon: "scope", question: "这项方法有哪些局限？")
                                }
                            }
                        }
                        ForEach(model.currentChats) { turn in
                            VStack(alignment: .leading, spacing: 14) {
                                Text(turn.question).font(.callout.weight(.medium)).padding(12).frame(
                                    maxWidth: .infinity, alignment: .leading
                                )
                                .background(ReaderTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
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
        }.background(ReaderTheme.surface)
    }

    private func prompt(_ title: String, icon: String, question value: String) -> some View {
        Button {
            question = value
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 16).foregroundStyle(ReaderTheme.accent)
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.left").font(.caption2).foregroundStyle(ReaderTheme.muted)
            }.font(.system(size: 12)).padding(12).background(ReaderTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
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
                        .foregroundStyle(.white).frame(width: 28, height: 28)
                        .background(ReaderTheme.accent, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityLabel("发送问题")
                    .opacity(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busyAI)
            }
        }.padding(14).background(ReaderTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ReaderTheme.line)).padding(16)
    }

    private var configured: Bool {
        (try? model.modelSettings.normalized()) != nil && (try? model.hasSavedAPIKey()) == true
    }
    private func translate() { if configured { model.startTranslation() } else { requestSettings() } }
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
        if width < 900 { showAssistantSheet = true } else { showAssistant.toggle() }
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
