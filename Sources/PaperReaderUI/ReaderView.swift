import PaperReaderKit
import SwiftUI

struct ReaderView: View {
    @Bindable var model: ReaderModel
    let openSettings: () -> Void
    @State private var showAssistant = false
    @State private var showAssistantSheet = false
    @State private var pendingSettings = false
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
                    }
                }, content: { assistant.frame(minWidth: 300, minHeight: 400) })
    }

    private func content(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                if width < 760 {
                    title
                    controls(width: width)
                } else {
                    HStack(spacing: 24) {
                        title
                        controls(width: width)
                    }
                }
            }.padding(.horizontal, 22).padding(.vertical, 18).background(ReaderTheme.surface)
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
                if showAssistant && width >= 800 {
                    Divider()
                    assistant.frame(width: 330)
                }
            }
        }
        .confirmationDialog("将本次讨论整理到笔记？", isPresented: $askSave, titleVisibility: .visible) {
            Button("包含讨论，保存笔记") { Task { await model.saveToObsidian(includeDiscussion: true) } }
            Button("不包含讨论，保存笔记") { Task { await model.saveToObsidian(includeDiscussion: false) } }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: model.mode) { _, _ in
            model.selectionText = ""
            model.selectionRects = []
            model.visiblePage = 0
        }
        .onChange(of: model.selectedPaperID) { _, _ in question = "" }
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
                Text("\(model.paper?.pageCount ?? 0) 页").font(.caption).foregroundStyle(ReaderTheme.muted)
            }
            Spacer(minLength: 0)
        }
    }

    private func controls(width: CGFloat) -> some View {
        HStack(spacing: 14) {
            if model.paper?.canReflow == true {
                Picker("阅读模式", selection: $model.mode) {
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
                askSave = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("保存到 Obsidian").accessibilityLabel("保存到 Obsidian")
            Button {
                toggleAssistant(width: width)
            } label: {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(showAssistant || showAssistantSheet ? ReaderTheme.accent : ReaderTheme.muted)
            }.help("论文讨论").accessibilityLabel("论文讨论")
        }.buttonStyle(.borderless).font(.system(size: 14))
    }

    private func readingBar(width: CGFloat) -> some View {
        HStack(spacing: 16) {
            Text("\(model.pageKeys.isEmpty ? 0 : model.visiblePage + 1) / \(model.pageKeys.count)")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(ReaderTheme.muted)
                .accessibilityLabel("第 \(model.visiblePage + 1) 页，共 \(model.pageKeys.count) 页")
            Spacer()
            if !model.selectionText.isEmpty {
                Button(action: model.highlightSelection) { Label("高亮", systemImage: "highlighter") }
                Button {
                    if width < 800 { showAssistantSheet = true } else { showAssistant = true }
                    question = "请结合全文解释选中内容。"
                } label: {
                    Label("解释", systemImage: "sparkles")
                }
            }
            #if os(iOS)
                Toggle(isOn: $penEnabled) { Image(systemName: "pencil.tip.crop.circle") }
                    .toggleStyle(.button).accessibilityLabel("手写批注")
            #endif
        }.buttonStyle(.borderless).font(.caption).padding(.horizontal, 24).frame(height: 42)
            .background(ReaderTheme.surface)
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("论文讨论").font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.busyAI { ProgressView().controlSize(.small) }
                Button {
                    showAssistant = false
                    showAssistantSheet = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(ReaderTheme.muted).accessibilityLabel("关闭讨论")
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if model.currentChats.isEmpty {
                        VStack(alignment: .leading, spacing: 20) {
                            Image(systemName: "sparkles").font(.system(size: 26, weight: .light)).foregroundStyle(
                                ReaderTheme.accent
                            )
                            .padding(.top, 16)
                            Text("一起读懂这篇论文").font(.system(size: 20, weight: .medium, design: .serif))
                            VStack(spacing: 8) {
                                prompt("核心贡献", icon: "lightbulb", question: "这篇论文主要解决什么问题，有哪些核心贡献？")
                                prompt(
                                    "方法思路", icon: "point.3.connected.trianglepath.dotted", question: "这篇论文的方法是如何工作的？")
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
                    if let summary = model.paper?.summary, !summary.isEmpty {
                        DisclosureGroup("论文总结") { Text(summary).font(.callout).textSelection(.enabled) }
                    }
                    Button {
                        if configured { Task { await model.summarize() } } else { requestSettings() }
                    } label: {
                        Label("生成总结", systemImage: "text.alignleft")
                    }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(ReaderTheme.muted).disabled(model.busyAI)
                }.padding(20)
            }
            composer
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
                Label("当前论文", systemImage: "doc.text").font(.system(size: 10)).foregroundStyle(ReaderTheme.muted)
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
        if width < 800 { showAssistantSheet = true } else { showAssistant.toggle() }
    }
    private func requestSettings() {
        if showAssistantSheet {
            pendingSettings = true
            showAssistantSheet = false
        } else {
            openSettings()
        }
    }
}
