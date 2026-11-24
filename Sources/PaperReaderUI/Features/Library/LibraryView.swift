import PaperReaderKit
import SwiftUI
import UniformTypeIdentifiers

public struct LibraryView: View {
    @Bindable var model: ReaderModel
    @State private var agent: LibraryAgent
    @State private var assistantTab: AssistantTab?
    @State private var paperOpenedFromAgent: UUID?
    @State private var paperQuestion = ""
    @State private var askSave = false
    @State private var agentDraft = ""
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var onlineSearch: OnlinePaperSearch
    @State private var selectedShelfID: UUID?
    @State private var calendarDate = Date()
    @State private var expandedNotebooks = Set<UUID>()
    @State private var dragTarget = false
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    @State private var toast: String?
    @State private var collection: LibraryCollection = .all
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var findRequest = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var sidebarSelection
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    public init(
        model: ReaderModel, agent: LibraryAgent? = nil, discovery: any PaperDiscovery = FederatedPaperDiscovery.shared
    ) {
        self.model = model
        _agent = State(initialValue: agent ?? LibraryAgent(reader: model, discovery: discovery))
        _onlineSearch = State(initialValue: OnlinePaperSearch(reader: model, discovery: discovery))
    }

    public var body: some View {
        navigationSurface
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) {
                result in
                switch result {
                case .success(let urls): Task { await model.importURLs(urls) }
                case .failure(let error): model.message = error.localizedDescription
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(model: model) { id in
                    model.select(id)
                    preferredColumn = .detail
                }
            }
            #if os(macOS)
                .focusedSceneValue(\.readerSettingsPresentation, $showSettings)
            #endif
            .alert(
                "PaperReader",
                isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
            ) {
                Button("好") { model.message = nil }
            } message: {
                Text(model.message ?? "")
            }
            .paperDeletionConfirmation()
            .task { await model.load() }
            .task(id: model.status) {
                guard model.loaded, model.status != "仅保存在此设备", !model.isImporting, model.translating.isEmpty else {
                    return
                }
                toast = model.status
                do {
                    try await Task.sleep(for: .seconds(4))
                    toast = nil
                } catch {}
            }
            .onChange(of: model.selectedPaperID) { _, id in
                if id != nil { preferredColumn = .detail }
                paperQuestion = ""
                if assistantTab != nil, id == nil || id != paperOpenedFromAgent {
                    assistantTab = isReading ? .paper : .library
                }
                paperOpenedFromAgent = nil
            }
            .onChange(of: scenePhase) { _, phase in
                #if os(macOS)
                    model.setActive(phase == .active, suspendTranslation: false)
                #else
                    model.setActive(phase == .active, suspendTranslation: phase == .background)
                #endif
            }
            .onReceive(timer) { _ in model.tick() }
    }

    private var navigationSurface: some View {
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $preferredColumn) {
            ZStack {
                if isReading {
                    ReaderNavigator(model: model, findRequest: findRequest) { preferredColumn = .detail }
                } else {
                    sidebar
                }
            }
            .modifier(WorkspaceArrival(page: isReading, distance: isReading ? 9 : -9, background: ReaderTheme.sidebar))
            .navigationSplitViewColumnWidth(min: 210, ideal: 244, max: 320)
        } detail: {
            detailContent
        }
        .tint(ReaderTheme.accent)
        .background {
            Button("查找") {
                findRequest += 1
                if isReading {
                    columns = .all
                    preferredColumn = .sidebar
                }
            }.keyboardShortcut("f").hidden().accessibilityHidden(true)
        }
        .background {
            Button("导入 PDF") { showImporter = true }
                .keyboardShortcut("o").hidden().accessibilityHidden(true)
        }
        .overlay {
            if dragTarget {
                RoundedRectangle(cornerRadius: 18).fill(ReaderTheme.accent.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18).strokeBorder(
                            ReaderTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    )
                    .overlay {
                        Label("添加到书库", systemImage: "arrow.down.doc").font(.title2.weight(.medium)).padding(30)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }.padding(12).allowsHitTesting(false).transition(.opacity)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }
            guard !pdfs.isEmpty else { return false }
            Task { await model.importURLs(pdfs) }
            return true
        } isTargeted: { targeted in
            withAnimation(ReaderMotion.feedback(reduceMotion)) { dragTarget = targeted }
        }
    }

    private var detailContent: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let inline = width >= 840
            let sidebarWidth = min(340, max(1, width - 36))
            let sidebarVisible = assistantTab != nil
            ZStack(alignment: .trailing) {
                workspaceContent
                    .transaction(value: sidebarVisible) { $0.animation = nil }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, inline && sidebarVisible ? sidebarWidth : 0)
                ZStack(alignment: .trailing) {
                    if let assistantTab {
                        WorkspaceAssistantSidebar(
                            model: model, agent: agent, isReading: isReading, tab: isReading ? assistantTab : .library,
                            select: { self.assistantTab = $0 }, question: $paperQuestion, agentDraft: $agentDraft,
                            openSettings: { showSettings = true }, saveNote: { askSave = true },
                            didNavigate: {
                                if !inline {
                                    self.assistantTab = nil
                                } else if assistantTab == .library {
                                    paperOpenedFromAgent = model.selectedPaperID
                                }
                            }
                        )
                        .frame(width: sidebarWidth)
                        .background(alignment: .leading) {
                            if !inline {
                                LinearGradient(
                                    colors: [.clear, .black.opacity(0.09)], startPoint: .leading, endPoint: .trailing
                                )
                                .frame(width: 8).offset(x: -8).allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                        .accessibilityAction(.escape) { self.assistantTab = nil }
                        .transition(.move(edge: .trailing))
                    }
                }
                .frame(width: sidebarWidth)
                .allowsHitTesting(sidebarVisible)
                .accessibilityHidden(!sidebarVisible)
            }
            .clipped()
            .animation(ReaderMotion.disclosure(reduceMotion), value: sidebarVisible)
        }
        .confirmationDialog("将本次讨论整理到笔记？", isPresented: $askSave, titleVisibility: .visible) {
            Button("包含讨论，保存笔记") { Task { await model.saveToObsidian(includeDiscussion: true) } }
            Button("不包含讨论，保存笔记") { Task { await model.saveToObsidian(includeDiscussion: false) } }
            Button("取消", role: .cancel) {}
        }
        .background(ReaderTheme.canvas)
        .task { HTMLWebViewPool.prewarm() }
        #if os(macOS)
            .toolbarBackground(ReaderTheme.canvas, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        #else
            .toolbar(removing: .title)
            .toolbarBackground(ReaderTheme.canvas, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    assistantTab = assistantTab == nil ? (isReading ? .paper : .library) : nil
                } label: {
                    Label(
                        "助读侧栏", systemImage: assistantTab == nil ? "sidebar.right" : "rectangle.righthalf.inset.filled"
                    )
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(assistantTab == nil ? "打开助读侧栏" : "收起助读侧栏")
                .accessibilityLabel(assistantTab == nil ? "打开助读侧栏" : "收起助读侧栏")
                .foregroundStyle(assistantTab != nil ? ReaderTheme.accent : ReaderTheme.muted)
                .disabled(!model.loaded || model.loadFailure != nil)
            }
        }
        .overlay(alignment: .bottom) {
            let busy = model.isImporting || (!isReading && !model.translating.isEmpty)
            ZStack(alignment: .bottom) {
                if busy {
                    HStack(spacing: 10) {
                        if model.isImporting, let progress = model.importProgress {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(progress).font(.caption).lineLimit(1)
                                ProgressView().progressViewStyle(.linear)
                                    .accessibilityLabel(progress)
                            }.frame(width: 250)
                        } else {
                            ProgressView().controlSize(.small)
                            Text(model.status).font(.caption).lineLimit(1)
                        }
                    }.padding(.horizontal, 18).padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule()).padding(18)
                } else if let toast {
                    Label(toast, systemImage: "checkmark.circle.fill").font(.caption).lineLimit(2)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule()).padding(18).allowsHitTesting(false)
                }
            }
            .animation(ReaderMotion.feedback(reduceMotion), value: busy || toast != nil)
        }
    }

    private var workspaceContent: some View {
        let page = workspacePage
        return ZStack {
            if let failure = model.loadFailure {
                ContentUnavailableView(
                    "无法打开书库", systemImage: "externaldrive.badge.exclamationmark", description: Text(failure))
            } else if !model.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch page {
                case .calendar:
                    ReadingCalendarView(model: model, date: $calendarDate)
                case .notebooks:
                    ReadingNotebooksView(model: model, expandedHistory: $expandedNotebooks)
                case .reader:
                    ReaderView(
                        model: model, sidebarOpen: assistantTab != nil,
                        explainSelection: {
                            paperQuestion = "请结合全文解释选中内容。"
                            assistantTab = .paper
                        }, openSettings: { showSettings = true })
                case .shelf:
                    LibraryWorkspaceView(
                        model: model, collection: $collection, selectedShelfID: $selectedShelfID,
                        onlineSearch: onlineSearch, findRequest: findRequest)
                }
            }
        }
        .modifier(WorkspaceArrival(page: page, distance: page.arrivalDistance, background: ReaderTheme.canvas))
    }

    private enum WorkspacePage {
        case shelf, reader, calendar, notebooks

        var arrivalDistance: CGFloat {
            switch self {
            case .reader: 32
            case .shelf: -24
            case .calendar, .notebooks: -16
            }
        }
    }

    private var workspacePage: WorkspacePage {
        switch model.selectedSection {
        case "calendar": .calendar
        case "notebooks": .notebooks
        default: model.currentEdition == nil ? .shelf : .reader
        }
    }

    private var isReading: Bool { workspacePage == .reader }

    private var recentPapers: [Paper] {
        model.state.papers.compactMap { paper in
            model.workspace(for: paper.id).lastOpenedAt.map { (paper: paper, date: $0) }
        }.sorted { $0.date > $1.date }.prefix(8).map(\.paper)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "book.pages.fill").font(.system(size: 20, weight: .regular))
                    .foregroundStyle(ReaderTheme.accent).accessibilityHidden(true)
                Text("PaperReader").font(ReaderTheme.editorial(24, weight: .medium)).foregroundStyle(ReaderTheme.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }.padding(.horizontal, 21).padding(.top, 17).padding(.bottom, 27)
            VStack(spacing: 3) {
                ForEach([LibraryCollection.all, .finished, .favorites]) { item in
                    navigation(
                        item.title, icon: item.icon,
                        selected: model.selectedSection == "library" && collection == item,
                        count: model.state.papers.filter { item.includes(model.workspace(for: $0.id), for: $0) }.count
                    ) {
                        model.select(nil)
                        collection = item
                        selectedShelfID = nil
                        preferredColumn = .detail
                    }
                }
                Rectangle().fill(ReaderTheme.line).frame(height: 1).padding(.vertical, 12).padding(.horizontal, 12)
                navigation("阅读日历", icon: "calendar", selected: model.selectedSection == "calendar") {
                    model.endReading()
                    model.selectedSection = "calendar"
                    preferredColumn = .detail
                }
                navigation("阅读笔记", icon: "book.pages", selected: model.selectedSection == "notebooks") {
                    model.endReading()
                    model.selectedSection = "notebooks"
                    preferredColumn = .detail
                }
            }
            .animation(ReaderMotion.disclosure(reduceMotion), value: collection)
            .animation(ReaderMotion.disclosure(reduceMotion), value: model.selectedSection)
            .padding(.horizontal, 10)
            let recent = recentPapers
            if !recent.isEmpty {
                Text("最近打开").font(.caption.weight(.medium)).foregroundStyle(ReaderTheme.muted)
                    .padding(.horizontal, 23).padding(.top, 28).padding(.bottom, 9)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(recent) { paper in
                            Button {
                                model.select(paper.id)
                                preferredColumn = .detail
                            } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: "doc.text").foregroundStyle(ReaderTheme.muted)
                                        .frame(width: 18).padding(.top, 1)
                                    Text(paper.title).foregroundStyle(ReaderTheme.ink).lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }.font(.callout).padding(.horizontal, 12).padding(.vertical, 8)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 10)
                }
            }
            Spacer(minLength: 14)
            Rectangle().fill(ReaderTheme.line).frame(height: 1).padding(.horizontal, 19)
            HStack(spacing: 8) {
                Button {
                    showImporter = true
                } label: {
                    Label("导入 PDF", systemImage: "plus").font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity).frame(minHeight: 40)
                        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(ReaderTheme.line) }
                }
                Button {
                    showSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape").labelStyle(.iconOnly)
                        .frame(width: 42, height: 42).contentShape(Rectangle())
                }.help("设置")
                    #if os(iOS)
                        .keyboardShortcut(",")
                    #endif
            }.buttonStyle(.plain).foregroundStyle(ReaderTheme.ink).padding(.horizontal, 17).padding(.vertical, 12)
        }.frame(maxHeight: .infinity).background(ReaderTheme.sidebar)
    }

    private func navigation(
        _ title: String, icon: String, selected: Bool, count: Int? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 18)
                    .foregroundStyle(selected ? ReaderTheme.accent : ReaderTheme.muted)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
                if let count, count > 0 {
                    Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(ReaderTheme.muted)
                }
            }.foregroundStyle(ReaderTheme.ink)
                .padding(.horizontal, 12).frame(minHeight: 38)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 9).fill(ReaderTheme.accent.opacity(0.095))
                            .matchedGeometryEffect(id: "library-selection", in: sidebarSelection)
                    }
                }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
