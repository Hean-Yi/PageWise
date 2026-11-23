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
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if displayedChats.isEmpty {
                        VStack(spacing: 0) {
                            prompt("核心贡献", icon: "lightbulb", question: "这篇论文主要解决什么问题，有哪些核心贡献？")
                            prompt(
                                "方法思路", icon: "point.3.connected.trianglepath.dotted",
                                question: "这篇论文的方法是如何工作的？")
                            prompt("局限与不足", icon: "scope", question: "这项方法有哪些局限？")
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
                                        didNavigate()
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
