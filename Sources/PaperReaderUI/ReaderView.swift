import PaperReaderKit
import SwiftUI

struct ReaderView: View {
    @Bindable var model: ReaderModel
    @State private var showAssistant = true
    @State private var showAssistantSheet = false
    @State private var penEnabled = false
    @State private var askSave = false
    @State private var question = ""

    var body: some View {
        GeometryReader { proxy in content(width: proxy.size.width) }
            .sheet(isPresented: $showAssistantSheet) {
                NavigationStack {
                    assistant.toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("关闭") { showAssistantSheet = false } }
                    }
                }.frame(minWidth: 300, minHeight: 400)
            }
    }

    private func content(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.paper?.title ?? "").font(.headline).lineLimit(1)
                    Text("固定版面 · 已发布页面保持不变").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("阅读模式", selection: $model.mode) {
                    Text("原始 PDF").tag("original")
                    if model.paper?.canReflow == true {
                        Text("原文重排").tag("reflow")
                        Text("双语阅读").tag("translated")
                    }
                }.pickerStyle(.segmented).frame(maxWidth: 280)
            }.padding(16)
            HStack(spacing: 12) {
                if model.translating.contains(model.selectedPaperID ?? UUID()) {
                    Button {
                        model.pauseTranslation()
                    } label: {
                        Label("暂停翻译", systemImage: "pause.fill")
                    }
                } else {
                    Button {
                        model.startTranslation()
                    } label: {
                        Label("翻译 / 继续", systemImage: "character.bubble")
                    }.disabled(model.paper?.canReflow != true)
                }
                Button {
                    model.highlightSelection()
                } label: {
                    Label("高亮选文", systemImage: "highlighter")
                }.disabled(model.selectionText.isEmpty)
                #if os(iOS)
                    Toggle(isOn: $penEnabled) { Label("手写", systemImage: "pencil.tip.crop.circle") }.toggleStyle(
                        .button)
                #endif
                Spacer()
                Button {
                    askSave = true
                } label: {
                    Label("保存笔记", systemImage: "square.and.arrow.up")
                }
                Button {
                    if width < 800 { showAssistantSheet = true } else { showAssistant.toggle() }
                } label: {
                    Label("讨论", systemImage: "sidebar.right")
                }
            }.buttonStyle(.borderless).font(.callout).padding(.horizontal, 16).padding(.bottom, 12)
            if let warnings = model.paper?.warnings, !warnings.isEmpty {
                HStack(alignment: .top) {
                    Image(systemName: "info.circle")
                    Text(warnings.joined(separator: " · ")).font(.caption).lineLimit(3)
                    Spacer()
                }.foregroundStyle(.secondary).padding(10).background(.orange.opacity(0.08))
            }
            Divider()
            HStack(spacing: 0) {
                Group {
                    if model.mode == "translated" && model.activePages.isEmpty && model.paper?.canReflow == true {
                        ContentUnavailableView(
                            "译文尚未生成", systemImage: "character.book.closed",
                            description: Text("先在设置中配置 GLM，再点击“翻译 / 继续”。\n前几段译好即可阅读，其余页面依次追加。"))
                    } else {
                        PDFCanvas(model: model, penEnabled: penEnabled)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if showAssistant && width >= 800 {
                    Divider()
                    assistant.frame(width: 310)
                }
            }
        }
        .confirmationDialog("是否将聊天记录整理到笔记当中？", isPresented: $askSave, titleVisibility: .visible) {
            Button("整理讨论并保存") { Task { await model.saveToObsidian(includeDiscussion: true) } }
            Button("仅保存阅读记录、批注和总结") { Task { await model.saveToObsidian(includeDiscussion: false) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("保留你在 Obsidian 中自己写的内容。已保存的历史讨论不会因本次选择而删除。")
        }
        .onChange(of: model.mode) { _, _ in
            model.selectionText = ""
            model.selectionRects = []
            model.visiblePage = 0
        }
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("阅读讨论", systemImage: "sparkle").font(.headline)
                Spacer()
                if model.busyAI { ProgressView().controlSize(.small) }
            }.padding(16)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.currentChats.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("从一个问题开始。").font(.system(.title3, design: .serif))
                            Text("选中正文后提问，先结合当前论文解释，再参考你的论文库与笔记。")
                                .font(.callout).foregroundStyle(.secondary)
                            ForEach(["这篇论文主要解决什么问题？", "请解释选中段落的核心思路", "这项方法有哪些局限？"], id: \.self) { prompt in
                                Button {
                                    question = prompt
                                } label: {
                                    Text(prompt).font(.caption).multilineTextAlignment(.leading)
                                }.buttonStyle(.bordered)
                            }
                        }.padding(.vertical, 12)
                    }
                    ForEach(model.currentChats) { turn in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(turn.question).font(.callout.bold()).padding(10).frame(
                                maxWidth: .infinity, alignment: .leading
                            ).background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            Text(turn.answer).font(.callout).textSelection(.enabled).lineSpacing(4)
                            DisclosureGroup("查看证据 · \(turn.evidence.count)") {
                                ForEach(turn.evidence) { source in
                                    Button {
                                        model.jump(to: source)
                                    } label: {
                                        Text(
                                            "[\(source.id)] \(source.title)\(source.sourcePage.map { " · 原文第 \($0 + 1) 页" } ?? "")"
                                        ).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                                    }.padding(.vertical, 3)
                                }
                            }.font(.caption)
                            Divider()
                        }
                    }
                    if let summary = model.paper?.summary, !summary.isEmpty {
                        DisclosureGroup("论文总结") { Text(summary).font(.callout).textSelection(.enabled) }
                    }
                    Button {
                        Task { await model.summarize() }
                    } label: {
                        Label("生成论文总结", systemImage: "text.alignleft")
                    }.disabled(model.busyAI)
                }.padding(.horizontal, 16).padding(.bottom, 16)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if !model.selectionText.isEmpty {
                    HStack(alignment: .top) {
                        Text(model.selectionText).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        Button {
                            model.selectionText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }.buttonStyle(.plain)
                    }.padding(9).background(.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
                TextField("问问这篇论文…", text: $question, axis: .vertical).lineLimit(2...5).textFieldStyle(.plain)
                HStack {
                    Text("当前论文优先 · 来源可追溯").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        let text = question
                        question = ""
                        Task { await model.ask(text) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busyAI)
                    .buttonStyle(.plain).foregroundStyle(.teal)
                }
            }.padding(14)
        }.background(.background)
    }
}
