import PaperReaderKit
import SwiftUI
import UniformTypeIdentifiers

public struct LibraryView: View {
    @Bindable var model: ReaderModel
    @State private var agent: LibraryAgent
    @State private var assistantTab: AssistantTab?
    @State private var paperOpenedFromAgent: UUID?
    @State private var paperQuestion = ""
    @State private var agentDraft = ""
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var settingsHint: String?
    @State private var guide = QuickStartNavigation()
    @State private var openingSample = false
    @AppStorage("completedQuickStart") private var completedQuickStart = false
    @State private var detailMetrics = DetailSidebarMetrics(width: 1100)
    @State private var leftSidebarWidth = SidebarWidthBox()
    @State private var onlineSearch: OnlinePaperSearch
    @State private var selectedShelfID: UUID?
    @State private var calendarDate = Date()
    @State private var calendarIconTurns = 0
    @State private var expandedNotebooks = Set<UUID>()
    @State private var notebookScroll = NotebookScrollBookmark()
    @State private var expandedNotebookAnnotations = Set<UUID>()
    @State private var dragTarget = false
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    @State private var toast: String?
    @State private var collection: LibraryCollection = .all
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var findRequest = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @ScaledMetric(relativeTo: .subheadline) private var sidebarFontSize: CGFloat = 13
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
            .environment(\.quickStartStep, guide.step)
            .onChange(of: selectedShelfID, initial: true) { _, shelf in model.activeShelfID = shelf }
            .overlayPreferenceValue(QuickStartAnchors.self) { anchors in
                if let step = guide.step {
                    GeometryReader { geometry in
                        QuickStartOverlay(
                            step: step, targetRect: anchors[step].map { geometry[$0] },
                            nextTitle: guideNextTitle,
                            isBusy: openingSample,
                            onBack: { moveGuide(-1) }, onNext: { moveGuide(1) }, onSkip: finishGuide,
                            onReadSample: openSample)
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) {
                result in
                switch result {
                case .success(let urls): importLibraryFiles(urls)
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { model.message = error.localizedDescription }
                }
            }
            .sheet(
                isPresented: $showSettings,
                onDismiss: {
                    settingsHint = nil
                    if guide.step == .modelSettings && model.isModelReadyForRequests {
                        moveGuide(1)
                    }
                }
            ) {
                SettingsView(
                    model: model,
                    contextHint: settingsHint,
                    openGuide: {
                        if beginGuide() { showSettings = false }
                    }
                ) { id in
                    model.select(id)
                    preferredColumn = .detail
                }
            }
            #if os(macOS)
                .focusedSceneValue(
                    \.quickStartPresentation,
                    model.loaded && !showSettings
                        ? Binding(get: { guide.step != nil }, set: { if $0 { beginGuide() } else { finishGuide() } })
                        : nil
                )
                .focusedSceneValue(\.readerSettingsPresentation, $showSettings)
            #endif
            .alert(
                "PageWise",
                isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
            ) {
                Button("好") { model.message = nil }
            } message: {
                Text(model.message ?? "")
            }
            .paperDeletionConfirmation()
            .task {
                await model.load()
                guard model.loaded, !completedQuickStart else { return }
                if model.state.papers.isEmpty { beginGuide() } else { completedQuickStart = true }
            }
            .task(id: guide.step) {
                if let step = guide.step { await navigateGuide(to: step) }
            }
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
                if id != nil {
                    preferredColumn = .detail
                    guide.didChooseLibraryPaper()
                }
                paperQuestion = ""
                if assistantTab != nil, id == nil || id != paperOpenedFromAgent {
                    assistantTab = isReading ? .paper : .library
                }
                paperOpenedFromAgent = nil
            }
            .onChange(of: model.closeReadingPaperID) { _, activeID in
                if activeID == nil { guide.resumeDeferredNavigation() }
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

    private var guideNextTitle: String? {
        if openingSample { return "正在打开…" }
        if guide.deferred != nil { return "等待精读…" }
        if guide.step == .modelSettings { return "试读示例" }
        return nil
    }

    @discardableResult private func beginGuide() -> Bool {
        guard model.closeReadingPaperID == nil else {
            model.status = "精读正在进行，结束后可打开快速上手"
            return false
        }
        guide = QuickStartNavigation(step: .importPaper)
        return true
    }

    private func finishGuide() {
        completedQuickStart = true
        guide = QuickStartNavigation()
    }

    private func moveGuide(_ distance: Int) {
        guard let current = guide.step, !openingSample else { return }
        if let next = QuickStartStep(rawValue: current.rawValue + distance) {
            if model.isImporting && (next == .bilingual || current == .bilingual) { return }
            if next.usesSample && (guide.sampleID == nil || model.selectedPaperID != guide.sampleID || !isReading) {
                openSampleForGuide(target: next)
                return
            }
            guide.request(next, closeReadingActive: model.closeReadingPaperID != nil)
        } else if distance > 0 {
            finishGuide()
        }
    }

    private func importLibraryFiles(_ urls: [URL]) {
        let startingStep = guide.step
        let stayOnShelf = guide.isChoosingPaper
        Task {
            let ids = await model.importURLs(urls, selectAfterImport: !stayOnShelf)
            if stayOnShelf, startingStep == guide.step, !ids.isEmpty {
                guide.didChooseLibraryPaper()
            }
        }
    }

    private func openSample() {
        guard !model.isImporting, !openingSample else { return }
        if guide.step != nil {
            openSampleForGuide(target: .bilingual)
        } else {
            Task { await model.openBundledSample() }
        }
    }

    private func openSampleForGuide(target: QuickStartStep) {
        guard !openingSample, !model.isImporting else { return }
        openingSample = true
        Task {
            defer { openingSample = false }
            let sampleID = await model.openBundledSample()
            guard !Task.isCancelled, guide.step != nil else { return }
            guard let sampleID else {
                guide.step = .modelSettings
                return
            }
            guide.sampleID = sampleID
            guide.request(target, closeReadingActive: model.closeReadingPaperID != nil)
        }
    }

    private func navigateGuide(to step: QuickStartStep) async {
        if !step.usesSample {
            columns = .all
            if model.selectedPaperID != nil { model.select(nil) }
            model.selectedSection = "library"
            collection = .all
            if assistantTab != nil {
                withAnimation(ReaderMotion.sidebar(reduceMotion)) { assistantTab = nil }
            }
            preferredColumn = .sidebar
        } else {
            if guide.sampleID == nil || model.selectedPaperID != guide.sampleID || !isReading {
                let sampleID = await model.openBundledSample()
                guard !Task.isCancelled, guide.step == step else { return }
                guard let sampleID else {
                    guide.step = .modelSettings
                    return
                }
                guide.sampleID = sampleID
            }
            preferredColumn = .detail
            let targetTab: AssistantTab? = step == .assistant ? .paper : nil
            if assistantTab != targetTab {
                withAnimation(ReaderMotion.sidebar(reduceMotion)) { assistantTab = targetTab }
            }
            if step == .annotation { model.showOriginalReading() }
        }
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
            .modifier(
                WorkspaceArrival(destination: CGPoint(x: isReading ? 9 : 0, y: 0), background: sidebarBackground)
            )
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: { width in
                if width >= 180 { leftSidebarWidth.width = width }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 244, max: 320)
            .toolbar(removing: .sidebarToggle)
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
                            .readerGlassSurface(in: RoundedRectangle(cornerRadius: 14), bordered: true)
                    }.padding(12).allowsHitTesting(false).transition(.opacity)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }
            guard !pdfs.isEmpty else { return false }
            importLibraryFiles(pdfs)
            return true
        } isTargeted: { targeted in
            withAnimation(ReaderMotion.feedback(reduceMotion)) { dragTarget = targeted }
        }
    }

    private var detailContent: some View {
        let inline = detailMetrics.inline
        let sidebarWidth = detailMetrics.sidebarWidth
        let sidebarVisible = assistantTab != nil
        let reservesSidebar = inline && sidebarVisible
        let isShelf = workspacePage == .shelf
        return ZStack(alignment: .trailing) {
            workspaceContent(trailingInset: isShelf && reservesSidebar ? sidebarWidth : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, !isShelf && reservesSidebar ? sidebarWidth : 0)
                // Give PDFKit, WebKit and non-shelf pages their final width once; bookshelf animates its single reflow via trailingInset.
                .transaction(value: reservesSidebar) { $0.animation = nil }
            if !inline && sidebarVisible {
                Color.black.opacity(0.14)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(ReaderMotion.sidebar(reduceMotion)) { self.assistantTab = nil }
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("收起助读侧栏")
                    .transition(.opacity)
            }
            ZStack(alignment: .trailing) {
                if let assistantTab {
                    WorkspaceAssistantSidebar(
                        model: model, agent: agent, isReading: isReading, tab: isReading ? assistantTab : .library,
                        select: { self.assistantTab = $0 }, question: $paperQuestion, agentDraft: $agentDraft,
                        showsCloseButton: !inline,
                        onClose: {
                            withAnimation(ReaderMotion.sidebar(reduceMotion)) { self.assistantTab = nil }
                        },
                        openSettings: {
                            settingsHint = "请先选择模型服务并保存 API 密钥，即可使用助读与精读功能。"
                            showSettings = true
                        },
                        didNavigate: {
                            if !inline {
                                withAnimation(ReaderMotion.sidebar(reduceMotion)) { self.assistantTab = nil }
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
                    .transition(reduceMotion ? .identity : .move(edge: .trailing))
                }
            }
            .frame(width: sidebarWidth)
            .allowsHitTesting(sidebarVisible)
            .accessibilityHidden(!sidebarVisible)
            .animation(ReaderMotion.sidebar(reduceMotion), value: sidebarVisible)
        }
        .clipped()
        .onGeometryChange(for: DetailSidebarMetrics.self) {
            DetailSidebarMetrics(width: $0.size.width)
        } action: { next in
            if detailMetrics != next { detailMetrics = next }
        }
        .obsidianExportPresentation(model: model)
        .background(ReaderTheme.canvas)
        .task { HTMLWebViewPool.prewarm() }
        .readerSystemToolbarBackground()
        #if os(iOS)
            .toolbar(removing: .title)
        #endif
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: toggleNavigationSidebar) {
                    Label(
                        "导航侧栏",
                        systemImage: navigationSidebarVisible ? "rectangle.lefthalf.inset.filled" : "sidebar.left"
                    )
                    .labelStyle(ReaderSymbolLabelStyle(iconOnly: true))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                }
                .readerIconButtonStyle(.automatic)
                .keyboardShortcut("s", modifiers: [.command, .control])
                .help(navigationSidebarVisible ? "收起导航侧栏（⌃⌘S）" : "打开导航侧栏（⌃⌘S）")
                .accessibilityLabel(navigationSidebarVisible ? "收起导航侧栏" : "打开导航侧栏")
                .foregroundStyle(navigationSidebarVisible ? ReaderTheme.accent : ReaderTheme.muted)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(ReaderMotion.sidebar(reduceMotion)) {
                        assistantTab = assistantTab == nil ? (isReading ? .paper : .library) : nil
                    }
                } label: {
                    Label(
                        "助读侧栏", systemImage: assistantTab == nil ? "sidebar.right" : "rectangle.righthalf.inset.filled"
                    )
                    .labelStyle(ReaderSymbolLabelStyle(iconOnly: true))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                }
                .readerIconButtonStyle(.automatic)
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(assistantTab == nil ? "打开助读侧栏（⌥⌘I）" : "收起助读侧栏（⌥⌘I）")
                .accessibilityLabel(assistantTab == nil ? "打开助读侧栏" : "收起助读侧栏")
                .foregroundStyle(assistantTab != nil ? ReaderTheme.accent : ReaderTheme.muted)
                .disabled(!model.loaded || model.loadFailure != nil)
            }
        }
        .overlay(alignment: .bottom) {
            LibraryStatusOverlay(model: model, isReading: isReading, toast: toast)
        }
    }

    private func workspaceContent(trailingInset: CGFloat) -> some View {
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
                    ReadingNotebooksView(
                        model: model, expandedHistory: $expandedNotebooks, bookmark: notebookScroll,
                        expandedAnnotations: $expandedNotebookAnnotations)
                case .reader:
                    ReaderView(
                        model: model, sidebarOpen: readerSidebarOpen,
                        explainSelection: {
                            paperQuestion = "请结合全文解释选中内容。"
                            assistantTab = .paper
                        },
                        openSettings: {
                            settingsHint = "请先选择模型服务并保存 API 密钥，即可开启双语重排与翻译。"
                            showSettings = true
                        })
                case .shelf:
                    LibraryWorkspaceView(
                        model: model, collection: $collection, selectedShelfID: $selectedShelfID,
                        onlineSearch: onlineSearch, findRequest: findRequest,
                        trailingInset: trailingInset,
                        navigationSidebarVisible: navigationSidebarVisible,
                        expectedLeftSidebarWidth: { leftSidebarWidth.width },
                        openSample: openSample)
                }
            }
        }
        .modifier(
            WorkspaceArrival(destination: page.location(origin: model.readerOrigin), background: ReaderTheme.canvas))
    }

    private var navigationSidebarVisible: Bool {
        #if os(iOS)
            if horizontalSizeClass == .compact { return preferredColumn == .sidebar }
        #endif
        return columns != .detailOnly
    }

    private func toggleNavigationSidebar() {
        withAnimation(ReaderMotion.sidebar(reduceMotion)) {
            #if os(iOS)
                if horizontalSizeClass == .compact {
                    preferredColumn = preferredColumn == .sidebar ? .detail : .sidebar
                    return
                }
            #endif
            columns = columns == .detailOnly ? .all : .detailOnly
        }
    }

    private var readerSidebarOpen: Bool {
        #if os(iOS)
            if horizontalSizeClass == .compact { return assistantTab != nil }
        #endif
        return assistantTab != nil || columns != .detailOnly
    }

    private enum WorkspacePage {
        case shelf, reader, calendar, notebooks

        func location(origin: ReaderOrigin) -> CGPoint {
            switch self {
            case .shelf: .zero
            case .calendar: CGPoint(x: 0, y: 9)
            case .notebooks: CGPoint(x: 0, y: 18)
            case .reader:
                switch origin {
                case .library: CGPoint(x: 26, y: 0)
                case .calendar: CGPoint(x: 26, y: 9)
                case .notebooks: CGPoint(x: 26, y: 18)
                }
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

    private var sidebarBackground: Color {
        if #available(macOS 26, iOS 26, *), !reduceTransparency {
            // Let NavigationSplitView supply the native sidebar material.
            return .clear
        }
        return ReaderTheme.sidebar
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image("Imprint", bundle: .module)
                    .resizable().interpolation(.high).scaledToFit().frame(width: 33, height: 33)
                    .brightness(colorScheme == .dark ? 0.18 : 0)
                    .accessibilityHidden(true)
                Text("PageWise").font(ReaderTheme.editorial(24, weight: .medium)).foregroundStyle(ReaderTheme.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }.padding(.horizontal, 21).padding(.top, 17).padding(.bottom, 27)
            VStack(spacing: 3) {
                ForEach(sidebarCollections, id: \.collection.id) { item, icon in
                    navigation(
                        item.title, icon: icon,
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
                navigation("阅读日历", icon: .calendar, selected: model.selectedSection == "calendar") {
                    calendarIconTurns += 1
                    model.endReading()
                    model.selectedSection = "calendar"
                    preferredColumn = .detail
                }.environment(\.calendarIconTurns, calendarIconTurns)
                navigation("阅读笔记", icon: .notebook, selected: model.selectedSection == "notebooks") {
                    model.endReading()
                    model.selectedSection = "notebooks"
                    preferredColumn = .detail
                }
            }
            .sidebarSelectionIndicator(
                for: model.selectedSection == "library" ? collection.id : model.selectedSection,
                in: RoundedRectangle(cornerRadius: 9), reduceMotion: reduceMotion
            )
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
                                    ReaderIcon(.paper, size: 16).foregroundStyle(ReaderTheme.muted)
                                        .frame(width: 18).padding(.top, 1)
                                    Text(paper.displayTitle).foregroundStyle(ReaderTheme.ink).lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }.font(.callout).padding(.horizontal, 12).padding(.vertical, 8)
                                    .contentShape(Rectangle())
                            }.readerIconButtonStyle(.plain)
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
                    Label("导入 PDF", readerIcon: .add, size: 16).font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity).frame(minHeight: 40)
                        .readerGlassSurface(in: RoundedRectangle(cornerRadius: 10), bordered: true)
                }
                .readerIconButtonStyle(.plain).quickStartTarget(.importPaper)
                Button {
                    settingsHint =
                        guide.step == .modelSettings
                        ? "选择一个模型服务并保存 API 密钥后，即可继续体验双语重排与助读。" : nil
                    showSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape").labelStyle(
                        ReaderSymbolLabelStyle(iconOnly: true, motion: .settings)
                    )
                    .frame(width: 42, height: 42).contentShape(Rectangle())
                }.readerIconButtonStyle(.plain).help("设置").quickStartTarget(.modelSettings)
                    #if os(iOS)
                        .keyboardShortcut(",")
                    #endif
            }.buttonStyle(.plain).foregroundStyle(ReaderTheme.ink).padding(.horizontal, 17).padding(.vertical, 12)
        }.frame(maxHeight: .infinity)
    }

    private var sidebarCollections: [(collection: LibraryCollection, icon: ReaderIcon.Glyph)] {
        [(.all, .library), (.finished, .read), (.favorites, .favorite)]
    }

    private func navigation(
        _ title: String, icon: ReaderIcon.Glyph, selected: Bool, count: Int? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ReaderIcon(icon, size: 17, sidebarSelected: selected).frame(minWidth: 18)
                Text(title).font(.system(size: sidebarFontSize, weight: selected ? .semibold : .regular))
                Spacer()
                if let count, count > 0 {
                    Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(ReaderTheme.muted)
                }
            }.foregroundStyle(ReaderTheme.ink)
                .padding(.horizontal, 12).frame(minHeight: 38)
                .sidebarSelectionTarget(selected)
                .contentShape(Rectangle())
        }.readerIconButtonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor private final class SidebarWidthBox {
    var width: CGFloat = 244
}

private struct DetailSidebarMetrics: Equatable {
    let inline: Bool
    let sidebarWidth: CGFloat

    init(width: CGFloat) {
        inline = width >= 840
        sidebarWidth = width >= 376 ? 340 : max(1, floor(width - 36))
    }
}

private struct LibraryStatusOverlay: View {
    let model: ReaderModel
    let isReading: Bool
    let toast: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
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
                    .readerGlassSurface(in: Capsule(), bordered: true).padding(18)
            } else if let toast {
                Label(toast, systemImage: "checkmark.circle.fill").font(.caption).lineLimit(2)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .readerGlassSurface(in: Capsule(), bordered: true).padding(18).allowsHitTesting(false)
            }
        }
        .animation(ReaderMotion.feedback(reduceMotion), value: busy || toast != nil)
    }
}

/// Only the bundled document can become the guide's reading example.
struct QuickStartNavigation {
    var step: QuickStartStep?
    var sampleID: UUID?
    private(set) var deferred: QuickStartStep?

    init(step: QuickStartStep? = nil) {
        self.step = step
    }

    var isChoosingPaper: Bool { step == .importPaper }

    mutating func didChooseLibraryPaper() {
        guard isChoosingPaper, let step else { return }
        self.step = QuickStartStep(rawValue: step.rawValue + 1)
    }

    mutating func request(_ next: QuickStartStep, closeReadingActive: Bool) {
        // Leaving the reader cancels its close-reading task. Keep it mounted until its notes finish saving.
        if closeReadingActive && !next.usesSample {
            deferred = next
            return
        }
        deferred = nil
        step = next
    }

    mutating func resumeDeferredNavigation() {
        guard let deferred else { return }
        step = deferred
        self.deferred = nil
    }
}
