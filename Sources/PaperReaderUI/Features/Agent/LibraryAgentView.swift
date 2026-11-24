import PaperReaderKit
import SwiftUI

struct LibraryAgentView: View {
    @Bindable var agent: LibraryAgent
    @Bindable var model: ReaderModel
    @Binding var draft: String
    let openSettings: () -> Void
    let didNavigate: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool
    @State private var choicesContentHeight: CGFloat?

    private var isConfigured: Bool {
        (try? model.modelSettings.normalized()) != nil
    }

    private var clarificationTurn: AgentTurn? {
        guard agent.pendingClarificationTurnID != nil, agent.followUpCardID == nil else { return nil }
        return agent.turns.last
    }

    var body: some View {
        let pending = clarificationTurn
        return GeometryReader { area in
            VStack(spacing: 0) {
                if agent.turns.isEmpty {
                    ScrollView { welcome.padding(20) }
                } else {
                    AgentTranscriptView(
                        agent: agent, activeQuestionID: pending?.id, didNavigate: didNavigate,
                        followUp: prepareFollowUp,
                        retry: { turn in
                            agent.clearFollowUp()
                            if let id = turn.referencedCardID { _ = agent.prepareFollowUp(cardID: id) }
                            draft = turn.question
                            composerFocused = true
                        })
                }
                composer(prompt: pending?.clarification, choicesHeight: max(76, area.size.height * 0.43)).padding(12)
            }
        }
        .background(ReaderTheme.canvas).foregroundStyle(ReaderTheme.ink)
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            suggestion("检索阅读笔记", icon: "note.text", prompt: "我之前在哪些笔记里讨论过注意力机制？")
            suggestion("在线查找论文", icon: "globe", prompt: "帮我在线查找 Attention Is All You Need")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestion(_ label: String, icon: String, prompt: String) -> some View {
        AssistantSuggestion(title: label, systemImage: icon) {
            draft = prompt
            composerFocused = true
        }
    }

    private func prepareFollowUp(_ card: AgentCard) {
        let prepared = withAnimation(ReaderMotion.disclosure(reduceMotion)) { agent.prepareFollowUp(cardID: card.id) }
        guard prepared else { return }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if card.readingNoteID != nil {
                draft = "这条阅读笔记和上面的判断有什么联系？"
            } else {
                draft = card.kind == .evidence ? "这段原文如何支持上面的回答？" : "这篇论文与我的问题有什么关联？"
            }
        }
        composerFocused = true
    }

    private func composer(prompt: AgentClarification?, choicesHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let prompt {
                ScrollView {
                    choices(prompt)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            choicesContentHeight = $0
                        }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(choicesContentHeight ?? choicesHeight, choicesHeight))
                Divider()
            }
            if let source = agent.followUpCard {
                HStack(spacing: 6) {
                    Image(systemName: "text.quote").foregroundStyle(ReaderTheme.accent).accessibilityHidden(true)
                    Text(source.title).lineLimit(1)
                    Spacer(minLength: 2)
                    Button {
                        withAnimation(ReaderMotion.disclosure(reduceMotion)) { agent.clearFollowUp() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).accessibilityLabel("移除追问来源").help("移除追问来源")
                }
                .font(.caption).foregroundStyle(ReaderTheme.muted)
                .padding(.vertical, 5).padding(.horizontal, 8).background(ReaderTheme.elevated, in: Capsule())
            }
            TextField(
                prompt == nil ? "问一个问题，或找一篇论文…" : "写下你的回答…", text: $draft, axis: .vertical
            )
            .textFieldStyle(.plain).font(.title3).lineLimit(3...5)
            .frame(minHeight: prompt == nil ? 60 : 44, alignment: .top)
            .focused($composerFocused).onSubmit(send)
            .accessibilityLabel(prompt == nil ? "向书库 Agent 提问" : "自定义回答")
            HStack {
                if !agent.turns.isEmpty {
                    Button {
                        agent.reset()
                        draft = ""
                        composerFocused = true
                    } label: {
                        Image(systemName: "square.and.pencil").frame(minWidth: 30, minHeight: 30)
                    }.buttonStyle(.plain).foregroundStyle(ReaderTheme.muted)
                        .help("新对话").accessibilityLabel("新对话")
                }
                Spacer(minLength: 6)
                Button {
                    if agent.isRunning { agent.cancel() } else { send() }
                } label: {
                    Image(systemName: agent.isRunning ? "stop.fill" : "arrow.up")
                        .font(agent.isRunning ? .system(size: 11) : .body.weight(.semibold))
                        .contentTransition(reduceMotion ? .identity : .opacity)
                        .animation(ReaderMotion.feedback(reduceMotion), value: agent.isRunning)
                }
                .buttonStyle(AssistantSendButtonStyle())
                .disabled(!agent.isRunning && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(agent.isRunning ? "停止生成" : "发送问题")
                .accessibilityLabel(agent.isRunning ? "停止 Agent" : "发送给 Agent")
            }
        }
        .assistantComposerSurface(emphasized: composerFocused || prompt != nil)
    }

    private func choices(_ prompt: AgentClarification) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(ReaderTheme.accent).accessibilityHidden(true)
                Text(prompt.question).font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            }.padding(.bottom, 9)
            ForEach(prompt.options, id: \.self) { option in
                Button {
                    draft = option
                    send()
                } label: {
                    HStack {
                        Text(option).font(.body)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                            .foregroundStyle(ReaderTheme.accent).accessibilityHidden(true)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(AssistantToolButtonStyle(embedded: true))
                if option != prompt.options.last { Divider() }
            }
        }
    }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !agent.isRunning else { return }
        guard isConfigured else {
            openSettings()
            return
        }
        agent.send(question, referencing: agent.followUpCard?.id)
        if agent.isRunning { draft = "" }
    }

}
