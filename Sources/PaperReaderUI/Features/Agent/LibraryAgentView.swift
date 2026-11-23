import PaperReaderKit
import SwiftUI

struct LibraryAgentView: View {
    @Bindable var agent: LibraryAgent
    @Bindable var model: ReaderModel
    @Binding var draft: String
    let openSettings: () -> Void
    let didNavigate: () -> Void
    @FocusState private var composerFocused: Bool
    @State private var hasMoreBelow = false

    private var isConfigured: Bool {
        (try? model.modelSettings.normalized()) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if agent.turns.isEmpty {
                            welcome
                        } else {
                            ForEach(agent.turns) { turn in conversation(turn).id(turn.id) }
                            if agent.isRunning, agent.turns.last?.activities.last?.status != .running,
                                agent.turns.last?.answer.isEmpty == true
                            {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.mini)
                                    Text("正在思考…").font(.system(size: 11)).foregroundStyle(ReaderTheme.muted)
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("agent-bottom")
                    }.padding(20)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.visibleRect.maxY > 48
                } action: { _, hasMore in
                    hasMoreBelow = hasMore
                }
                .overlay(alignment: .bottomTrailing) {
                    if hasMoreBelow, !agent.turns.isEmpty {
                        Button {
                            proxy.scrollTo("agent-bottom", anchor: .bottom)
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.callout.weight(.medium))
                                .frame(width: 34, height: 34).background(ReaderTheme.surface, in: Circle())
                                .overlay { Circle().strokeBorder(ReaderTheme.line) }
                        }
                        .buttonStyle(.plain).foregroundStyle(ReaderTheme.ink)
                        .help("前往最新消息").accessibilityLabel("前往最新消息")
                        .padding(.trailing, 15).padding(.bottom, 6)
                    }
                }
                .onChange(of: agent.turns.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .top) }
                }
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

    private func conversation(_ turn: AgentTurn) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(turn.question).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                .padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(ReaderTheme.elevated, in: RoundedRectangle(cornerRadius: 12))
            if !turn.activities.isEmpty {
                VStack(spacing: 7) {
                    ForEach(turn.activities) { activity in
                        AgentActivityCard(
                            activity: activity, cards: turn.cards(for: activity), agent: agent, didNavigate: didNavigate
                        )
                    }
                }
            }
            if !turn.answer.isEmpty {
                Text(answerText(turn.answer)).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = turn.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(ReaderTheme.muted)
                    Button("重新提问") {
                        draft = turn.question
                        composerFocused = true
                    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(ReaderTheme.accent)
                }
            } else if turn.isCancelled, turn.activities.last?.status != .cancelled {
                Text("已停止").font(.system(size: 11)).foregroundStyle(ReaderTheme.muted)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("问一个问题，或找一篇论文…", text: $draft, axis: .vertical)
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
        draft = ""
        agent.send(question)
    }

    /// Tool cards are the navigation surface; generated prose cannot supply action links.
    private func answerText(_ text: String) -> AttributedString {
        var result =
            (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in result.runs where run.link != nil { result[run.range].link = nil }
        return result
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
