import SwiftUI

enum AssistantTab: String, CaseIterable {
    case paper = "论文助读"
    case notes = "笔记"
    case library = "书库助理"

    var icon: String {
        switch self {
        case .paper: "text.bubble"
        case .notes: "note.text"
        case .library: "books.vertical"
        }
    }
}

struct WorkspaceAssistantSidebar: View {
    let model: ReaderModel
    let agent: LibraryAgent
    let isReading: Bool
    let tab: AssistantTab
    let select: (AssistantTab) -> Void
    @Binding var question: String
    @Binding var agentDraft: String
    let openSettings: () -> Void
    let saveNote: () -> Void
    let didNavigate: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabSelection

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if isReading {
                    ForEach(AssistantTab.allCases, id: \.self) { item in
                        Button {
                            select(item)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: item.icon)
                                if tab == item { Text(item.rawValue).font(.callout.weight(.medium)).lineLimit(1) }
                            }
                            .frame(minWidth: 36, maxWidth: .infinity, minHeight: 34)
                            .padding(.horizontal, 8)
                            .foregroundStyle(tab == item ? ReaderTheme.accent : ReaderTheme.muted)
                            .background {
                                if tab == item {
                                    Capsule().fill(ReaderTheme.elevated)
                                        .matchedGeometryEffect(id: "selected-tab", in: tabSelection)
                                        .transition(.identity)
                                }
                            }
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(item.rawValue).accessibilityLabel(item.rawValue)
                        .accessibilityAddTraits(tab == item ? .isSelected : [])
                    }
                } else {
                    Label(AssistantTab.library.rawValue, systemImage: AssistantTab.library.icon)
                        .font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                }
                if model.busyAI && isReading {
                    ProgressView().controlSize(.small).opacity(tab == .library ? 0 : 1)
                        .accessibilityHidden(tab == .library)
                }
            }.padding(.horizontal, 14).frame(height: 56)
                .animation(ReaderMotion.disclosure(reduceMotion), value: tab)
            Divider()
            ZStack {
                tabContent.id(tab).transition(.opacity)
            }
            .animation(ReaderMotion.disclosure(reduceMotion), value: tab)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReaderTheme.canvas)
        .overlay(alignment: .leading) { Rectangle().fill(ReaderTheme.line).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("助读侧栏")
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .library:
            LibraryAgentView(
                agent: agent, model: model, draft: $agentDraft, openSettings: openSettings, didNavigate: didNavigate
            )
        case .notes:
            ReaderNotesView(
                model: model,
                summarize: {
                    if (try? model.modelSettings.normalized()) != nil {
                        Task { await model.summarize() }
                    } else {
                        openSettings()
                    }
                }, saveNote: saveNote, didNavigate: didNavigate)
        case .paper:
            PaperAssistantView(
                model: model, question: $question, openSettings: openSettings, didNavigate: didNavigate,
                relatedPapers: {
                    guard (try? model.modelSettings.normalized()) != nil else {
                        openSettings()
                        return
                    }
                    select(.library)
                    agent.findRelatedToCurrentPaper()
                }, canFindRelated: !agent.isRunning && model.paper != nil)
        }
    }
}
