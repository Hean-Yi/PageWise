import PaperReaderKit
import SwiftUI

struct LibraryAgentView: View {
    @Bindable var agent: LibraryAgent
    @Bindable var model: ReaderModel
    @Binding var draft: String
    let openSettings: () -> Void
    let didNavigate: () -> Void
    @FocusState private var composerFocused: Bool

    private var isConfigured: Bool {
        (try? model.modelSettings.normalized()) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if agent.turns.isEmpty {
                ScrollView { welcome.padding(20) }
            } else {
                AgentTranscriptView(
                    agent: agent, didNavigate: didNavigate, followUp: prepareFollowUp,
                    retry: { turn in
                        agent.clearFollowUp()
                        if let id = turn.referencedCardID { _ = agent.prepareFollowUp(cardID: id) }
                        draft = turn.question
                        composerFocused = true
                    })
            }
            composer.padding(16)
        }
        .background(ReaderTheme.canvas).foregroundStyle(ReaderTheme.ink)
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            suggestion("在书库中找知识点", icon: "text.magnifyingglass", prompt: "我的书库中，哪些段落解释了注意力机制？")
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
        guard agent.prepareFollowUp(cardID: card.id) else { return }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = card.kind == .evidence ? "这段原文如何支持上面的回答？" : "这篇论文与我的问题有什么关联？"
        }
        composerFocused = true
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let source = agent.followUpCard {
                HStack(spacing: 6) {
                    Image(systemName: "text.quote").foregroundStyle(ReaderTheme.accent).accessibilityHidden(true)
                    Text(source.title).lineLimit(1)
                    Spacer(minLength: 2)
                    Button {
                        agent.clearFollowUp()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).accessibilityLabel("移除追问来源").help("移除追问来源")
                }
                .font(.caption).foregroundStyle(ReaderTheme.muted)
                .padding(.vertical, 5).padding(.horizontal, 8).background(ReaderTheme.elevated, in: Capsule())
            }
            TextField(
                agent.pendingClarificationTurnID == nil ? "问一个问题，或找一篇论文…" : "输入你的偏好…", text: $draft, axis: .vertical
            )
            .textFieldStyle(.plain).lineLimit(2...5).font(.system(size: 13))
            .focused($composerFocused).onSubmit(send).accessibilityLabel("向书库 Agent 提问")
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
                if agent.isRunning {
                    Button(action: agent.cancel) { Image(systemName: "stop.fill").font(.system(size: 11)) }
                        .buttonStyle(AgentSendStyle()).help("停止生成").accessibilityLabel("停止 Agent")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold)) }
                        .buttonStyle(AgentSendStyle()).disabled(
                            draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        .help("发送问题").accessibilityLabel("发送给 Agent")
                }
            }
        }.padding(16).background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16).strokeBorder(
                    composerFocused ? ReaderTheme.accent.opacity(0.35) : ReaderTheme.line))
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

private struct AgentSendStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(ReaderTheme.surface)
            .frame(width: 30, height: 30)
            .background(
                ReaderTheme.ink.opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.25), in: Circle())
    }
}
