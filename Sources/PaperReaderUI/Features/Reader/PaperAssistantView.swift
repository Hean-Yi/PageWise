import PaperReaderKit
import SwiftUI

struct PaperAssistantView: View {
    @Bindable var model: ReaderModel
    @Binding var question: String
    let openSettings: () -> Void
    let didNavigate: () -> Void
    let relatedPapers: () -> Void
    let canFindRelated: Bool
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedThinking: Set<UUID> = []

    private var displayedChats: [ChatTurn] {
        model.currentChats + (model.currentAssistantDraft.map { [$0] } ?? [])
    }

    private var currentFailure: PaperAssistantFailure? {
        guard let failure = model.lastAssistantFailure, failure.paperID == model.selectedPaperID else { return nil }
        return failure
    }

    var body: some View {
        let chats = displayedChats
        let failure = currentFailure
        return VStack(alignment: .leading, spacing: 0) {
            CloseReadingControl(model: model, openSettings: openSettings)
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if chats.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                if !model.isModelReadyForRequests {
                                    HStack(spacing: 8) {
                                        Image(systemName: "slider.horizontal.3").foregroundStyle(ReaderTheme.accent)
                                        Text("配置模型服务后即可开始助读与精读").font(.caption).foregroundStyle(ReaderTheme.muted)
                                        Spacer(minLength: 4)
                                        Button("去设置", action: openSettings)
                                            .buttonStyle(.borderless).font(.caption.weight(.medium))
                                    }
                                    .padding(11)
                                    .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ReaderTheme.line))
                                }
                                Text("选中原文可直接解释，或从下方开始提问")
                                    .font(.caption).foregroundStyle(ReaderTheme.muted)
                                VStack(spacing: 0) {
                                    prompt("核心贡献", icon: "lightbulb", question: "这篇论文主要解决什么问题，有哪些核心贡献？")
                                    prompt(
                                        "方法思路", icon: "point.3.connected.trianglepath.dotted",
                                        question: "这篇论文的方法是如何工作的？")
                                    prompt("局限与不足", icon: "scope", question: "这项方法有哪些局限？")
                                }
                            }
                        }
                        ForEach(chats) { turn in
                            VStack(alignment: .leading, spacing: 14) {
                                Text(turn.question).font(.callout.weight(.medium)).padding(12).frame(
                                    maxWidth: .infinity, alignment: .leading
                                )
                                .background(ReaderTheme.elevated, in: RoundedRectangle(cornerRadius: 12))
                                if let reasoning = turn.reasoning, !reasoning.isEmpty {
                                    let isStreamingTurn = model.assistantDraft?.id == turn.id
                                    let showsThinking = expandedThinking.contains(turn.id)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Button {
                                            withAnimation(ReaderMotion.disclosure(reduceMotion)) {
                                                if showsThinking {
                                                    expandedThinking.remove(turn.id)
                                                } else {
                                                    expandedThinking.insert(turn.id)
                                                }
                                            }
                                        } label: {
                                            HStack(spacing: 7) {
                                                ReaderActionSymbol("text.bubble").frame(width: 15)
                                                Text("模型思考").fontWeight(.medium)
                                                Spacer(minLength: 4)
                                                ReaderActionSymbol("chevron.right").font(.caption2)
                                                    .rotationEffect(.degrees(showsThinking ? 90 : 0))
                                                    .accessibilityHidden(true)
                                            }
                                            .font(.caption).padding(.vertical, 3).contentShape(Rectangle())
                                        }
                                        .readerIconButtonStyle(.plain)
                                        .accessibilityValue(showsThinking ? "已展开" : "已收起")
                                        if showsThinking || isStreamingTurn {
                                            Text(reasoning)
                                                .font(.caption).lineSpacing(2)
                                                .lineLimit(showsThinking ? nil : 2)
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.leading, 11)
                                                .overlay(alignment: .leading) {
                                                    Rectangle().fill(ReaderTheme.line).frame(width: 1)
                                                }
                                                .padding(.leading, 7)
                                        }
                                    }
                                    .foregroundStyle(ReaderTheme.muted)
                                }
                                PaperAssistantCitations(turn: turn, model: model, didNavigate: didNavigate) {
                                    sourceID in
                                    scroll.scrollTo(
                                        AssistantCitationAnchor(turn: turn.id, source: sourceID), anchor: .top)
                                }
                                if model.assistantDraft?.id == turn.id,
                                    turn.answer.isEmpty || model.assistantActivityStatus != nil
                                {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.mini)
                                        Text(model.assistantActivityStatus ?? "正在准备回答…")
                                            .font(.caption).foregroundStyle(ReaderTheme.muted)
                                    }
                                    .accessibilityLabel(model.assistantActivityStatus ?? "正在处理请求")
                                }
                            }
                        }
                        if let failure {
                            failureCard(failure)
                        }
                        Color.clear.frame(height: 1).id("paper-chat-bottom")
                    }.padding(20)
                }
                .modifier(
                    JumpToLatest(
                        target: .init(turn: chats.last?.id, awaitsReply: failure != nil)
                    ) { scroll.scrollTo("paper-chat-bottom", anchor: .bottom) }
                )
                .onChange(of: chats.last?.readingNoteID) { _, id in
                    if id != nil { scroll.scrollTo("paper-chat-bottom", anchor: .bottom) }
                }
            }
            composer
        }
    }

    private func failureCard(_ failure: PaperAssistantFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Color.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.question).font(.caption.weight(.medium)).foregroundStyle(ReaderTheme.ink).lineLimit(2)
                    Text(failure.message).font(.caption).foregroundStyle(ReaderTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button {
                    model.lastAssistantFailure = nil
                } label: {
                    ReaderIcon(.close, size: 12).readerIconTarget(macOS: 22)
                }
                .readerIconButtonStyle(.plain).foregroundStyle(ReaderTheme.muted).accessibilityLabel("关闭错误提示")
            }
            HStack(spacing: 12) {
                Button("重试") {
                    guard model.isModelReadyForRequests else {
                        openSettings()
                        return
                    }
                    model.startAsking(failure.question)
                }
                .buttonStyle(.borderless).font(.caption.weight(.medium)).foregroundStyle(ReaderTheme.accent)
                .disabled(model.busyAI)
                Button("重新编辑") {
                    question = failure.question
                    model.lastAssistantFailure = nil
                    composerFocused = true
                }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(ReaderTheme.muted)
            }
        }
        .padding(12)
        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ReaderTheme.line))
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
                    Text(model.assistantSelectionText).font(.callout).foregroundStyle(ReaderTheme.muted).lineLimit(3)
                    Button {
                        model.clearAssistantSelection()
                    } label: {
                        ReaderIcon(.close, size: 13).readerIconTarget(macOS: 22)
                    }
                    .readerPlainButton(cornerRadius: 6).foregroundStyle(ReaderTheme.muted).accessibilityLabel("移除选文")
                }.fixedSize(horizontal: false, vertical: true)
            }
            TextField("问这篇论文…", text: $question, axis: .vertical)
                .textFieldStyle(.plain).font(.body).lineLimit(3...6)
                .frame(minHeight: 52, alignment: .top)
                .focused($composerFocused).onSubmit(send).accessibilityLabel("向论文助读提问")
            HStack {
                Button(action: relatedPapers) {
                    Label("相关论文", systemImage: "point.3.connected.trianglepath.dotted").labelStyle(
                        ReaderSymbolLabelStyle())
                }
                .font(.callout).readerIconButtonStyle(.borderless).foregroundStyle(ReaderTheme.muted)
                .help("查找与当前论文相关的研究").disabled(!canFindRelated)
                if let last = model.currentChats.last, last.readingNoteID == nil, !last.answer.isEmpty {
                    Button {
                        guard model.isModelReadyForRequests else {
                            openSettings()
                            return
                        }
                        Task { await model.ask("把刚才讨论的观点记为阅读笔记，并标画对应原文。") }
                    } label: {
                        ReaderActionSymbol("note.text.badge.plus").frame(minWidth: 30, minHeight: 30)
                    }
                    .readerIconButtonStyle(.plain).foregroundStyle(ReaderTheme.muted)
                    .help("将刚才的讨论记为笔记").accessibilityLabel("将刚才的讨论记为笔记")
                    .disabled(model.busyAI)
                }
                Spacer()
                Button {
                    if model.busyAI { model.cancelAssistant() } else { send() }
                } label: {
                    ReaderActionSymbol(model.busyAI ? "stop.fill" : "arrow.up")
                        .font(model.busyAI ? .system(size: 11) : .body.weight(.semibold))
                        .contentTransition(reduceMotion ? .identity : .opacity)
                        .animation(ReaderMotion.feedback(reduceMotion), value: model.busyAI)
                }
                .readerIconButtonStyle(AssistantSendButtonStyle())
                .help(model.busyAI ? "停止生成" : "发送问题（Return 发送，Option+Return 换行）")
                .accessibilityLabel(model.busyAI ? "停止生成" : "发送问题")
                .disabled(!model.busyAI && question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .assistantComposerSurface(emphasized: composerFocused || !model.assistantSelectionText.isEmpty)
        .padding(12)
    }

    private func send() {
        guard model.isModelReadyForRequests else {
            openSettings()
            return
        }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.busyAI else { return }
        question = ""
        model.startAsking(text)
    }
}
