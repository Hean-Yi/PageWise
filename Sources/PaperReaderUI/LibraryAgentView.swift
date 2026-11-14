import PaperReaderKit
import SwiftUI

struct LibraryAgentView: View {
    @Bindable var agent: LibraryAgent
    @Bindable var model: ReaderModel
    @Binding var draft: String
    let openSettings: () -> Void
    let close: () -> Void
    let didNavigate: () -> Void
    @FocusState private var composerFocused: Bool

    private var isConfigured: Bool {
        (try? model.modelSettings.normalized()) != nil && (try? model.hasSavedAPIKey()) == true
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if agent.turns.isEmpty {
                            welcome
                        } else {
                            ForEach(agent.turns) { turn in conversation(turn) }
                            if agent.isRunning {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.mini)
                                    Text("正在思考…").font(.system(size: 11)).foregroundStyle(ReaderTheme.muted)
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("agent-bottom")
                    }.padding(20)
                }
                .onChange(of: agent.turns.count) { _, _ in proxy.scrollTo("agent-bottom", anchor: .bottom) }
                .onChange(of: agent.turns.last?.answer) { _, _ in proxy.scrollTo("agent-bottom", anchor: .bottom) }
            }
            composer.padding(16)
        }
        .background(ReaderTheme.canvas).foregroundStyle(ReaderTheme.ink)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle").foregroundStyle(ReaderTheme.accent)
            Text("Agent").font(.system(size: 14, weight: .medium))
            Text("书库").font(.system(size: 10)).foregroundStyle(ReaderTheme.muted)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(ReaderTheme.ink.opacity(0.045), in: Capsule())
            Spacer()
            Button {
                agent.reset()
                draft = ""
                composerFocused = true
            } label: {
                Image(systemName: "square.and.pencil")
            }.buttonStyle(.plain).help("新对话 · 当前会话仅在本次运行保留").accessibilityLabel("新对话")
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).frame(width: 25, height: 25)
            }.buttonStyle(.plain).foregroundStyle(ReaderTheme.muted).help("关闭 Agent").accessibilityLabel("关闭 Agent")
        }.padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "sparkle").font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(ReaderTheme.accent).padding(.top, 32)
            VStack(alignment: .leading, spacing: 9) {
                Text("让阅读彼此连接").font(.system(size: 23, weight: .regular, design: .serif))
                Text("查论文，找线索，回到原文。").font(.system(size: 12)).foregroundStyle(ReaderTheme.muted)
            }
            VStack(spacing: 10) {
                suggestion("找一个知识点", icon: "text.magnifyingglass", prompt: "我的书库中，哪些段落解释了注意力机制？")
                suggestion("查找一篇论文", icon: "globe", prompt: "帮我在线查找 Attention Is All You Need")
                if let paper = model.paper {
                    suggestion("理解当前论文", icon: "book", prompt: "请查找《\(paper.title)》，结合原文解释主要方法并标注来源页。")
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestion(_ label: String, icon: String, prompt: String) -> some View {
        Button {
            draft = prompt
            composerFocused = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 16).foregroundStyle(ReaderTheme.muted)
                Text(label)
                Spacer()
                Image(systemName: "arrow.up.left").font(.system(size: 10)).foregroundStyle(ReaderTheme.muted)
            }.font(.system(size: 12)).padding(13)
                .background(ReaderTheme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ReaderTheme.line))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func conversation(_ turn: AgentTurn) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(turn.question).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                .padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(ReaderTheme.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            if !turn.activities.isEmpty { AgentActivityLog(activities: turn.activities) }
            if !turn.answer.isEmpty {
                Text(answerText(turn.answer)).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(turn.cards) { card in
                AgentResultCard(
                    card: card,
                    open: { if agent.open(cardID: card.id) { didNavigate() } },
                    importPaper: { agent.confirmImport(cardID: card.id) },
                    stopImport: { agent.cancelImport(cardID: card.id) })
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
            } else if turn.isCancelled {
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
                Button(action: openSettings) {
                    Label(isConfigured ? model.modelSettings.model : "配置模型", systemImage: "slider.horizontal.3")
                        .lineLimit(1)
                }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(ReaderTheme.muted)
                    .help("模型服务设置")
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
        }.padding(14).background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(
                RoundedRectangle(cornerRadius: 13).strokeBorder(
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
                ReaderTheme.accent.opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.25),
                in: RoundedRectangle(cornerRadius: 8))
    }
}
