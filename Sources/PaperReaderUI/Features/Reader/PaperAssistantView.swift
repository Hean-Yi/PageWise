import PaperReaderKit
import SwiftUI

struct PaperAssistantView: View {
    @Bindable var model: ReaderModel
    @Binding var question: String
    let openSettings: () -> Void
    let didNavigate: () -> Void
    @FocusState private var composerFocused: Bool

    private var displayedChats: [ChatTurn] {
        model.currentChats + (model.assistantDraft.flatMap { $0.paperID == model.selectedPaperID ? [$0] : nil } ?? [])
    }

    var body: some View {
        let chats = displayedChats
        return VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if chats.isEmpty {
                            VStack(spacing: 0) {
                                prompt("核心贡献", icon: "lightbulb", question: "这篇论文主要解决什么问题，有哪些核心贡献？")
                                prompt(
                                    "方法思路", icon: "point.3.connected.trianglepath.dotted",
                                    question: "这篇论文的方法是如何工作的？")
                                prompt("局限与不足", icon: "scope", question: "这项方法有哪些局限？")
                            }
                        }
                        ForEach(chats) { turn in
                            VStack(alignment: .leading, spacing: 14) {
                                Text(turn.question).font(.callout.weight(.medium)).padding(12).frame(
                                    maxWidth: .infinity, alignment: .leading
                                )
                                .background(ReaderTheme.elevated, in: RoundedRectangle(cornerRadius: 12))
                                PaperAssistantCitations(turn: turn, model: model, didNavigate: didNavigate) {
                                    sourceID in
                                    scroll.scrollTo(
                                        AssistantCitationAnchor(turn: turn.id, source: sourceID), anchor: .top)
                                }
                                if model.assistantDraft?.id == turn.id, turn.answer.isEmpty {
                                    ProgressView().controlSize(.small).accessibilityLabel("正在处理请求")
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("paper-chat-bottom")
                    }.padding(20)
                }
                .onChange(of: chats.last?.readingNoteID) { _, id in
                    if id != nil { scroll.scrollTo("paper-chat-bottom", anchor: .bottom) }
                }
            }
            composer
        }
    }

    private func prompt(_ title: String, icon: String, question value: String) -> some View {
        AssistantSuggestion(title: title, systemImage: icon) {
            question = value
            composerFocused = true
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.assistantSelectionText.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Rectangle().fill(ReaderTheme.accent).frame(width: 2)
                    Text(model.assistantSelectionText).font(.caption).foregroundStyle(ReaderTheme.muted).lineLimit(3)
                    Button {
                        model.clearAssistantSelection()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(ReaderTheme.muted).accessibilityLabel("移除选文")
                }.fixedSize(horizontal: false, vertical: true)
            }
            TextField("问这篇论文…", text: $question, axis: .vertical).lineLimit(2...6).textFieldStyle(.plain).font(.callout)
                .focused($composerFocused).onSubmit(send)
            HStack {
                if let last = model.currentChats.last, last.readingNoteID == nil, !last.answer.isEmpty {
                    Button {
                        guard (try? model.modelSettings.normalized()) != nil else {
                            openSettings()
                            return
                        }
                        Task { await model.ask("把刚才讨论的观点记为阅读笔记，并标画对应原文。") }
                    } label: {
                        Image(systemName: "note.text.badge.plus").frame(minWidth: 30, minHeight: 30)
                    }
                    .buttonStyle(.plain).foregroundStyle(ReaderTheme.muted)
                    .help("将刚才的讨论记为笔记").accessibilityLabel("将刚才的讨论记为笔记")
                    .disabled(model.busyAI)
                }
                Spacer()
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ReaderTheme.surface).frame(width: 30, height: 30)
                        .background(ReaderTheme.ink, in: Circle())
                }.buttonStyle(.plain).help("发送问题").accessibilityLabel("发送问题")
                    .opacity(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busyAI)
            }
        }.padding(16).background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16).strokeBorder(
                    composerFocused ? ReaderTheme.accent.opacity(0.35) : ReaderTheme.line)
            ).padding(14)
    }

    private func send() {
        guard (try? model.modelSettings.normalized()) != nil else {
            openSettings()
            return
        }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.busyAI else { return }
        question = ""
        Task { await model.ask(text) }
    }
}
