import Foundation
import PaperReaderKit

extension ReaderModel {
    public func workspace(for paperID: UUID) -> PaperWorkspace {
        state.workspace[paperID.uuidString] ?? PaperWorkspace()
    }

    public func setReadingStatus(_ status: PaperReadingStatus, for paperID: UUID) {
        guard state.papers.contains(where: { $0.id == paperID }) else { return }
        var workspace = workspace(for: paperID)
        guard workspace.status != status else { return }
        workspace.status = status
        state.workspace[paperID.uuidString] = workspace
        workspaceRevision += 1
        scheduleWorkspaceSave(immediately: true)
    }

    public func toggleFavorite(_ paperID: UUID) {
        guard state.papers.contains(where: { $0.id == paperID }) else { return }
        var workspace = workspace(for: paperID)
        workspace.isFavorite.toggle()
        state.workspace[paperID.uuidString] = workspace
        workspaceRevision += 1
        scheduleWorkspaceSave(immediately: true)
    }

    public var currentBookmarks: [PageBookmark] {
        state.bookmarks.filter { $0.paperID == selectedPaperID }.sorted { $0.createdAt > $1.createdAt }
    }

    public var isCurrentPageBookmarked: Bool {
        guard let position = currentPosition else { return false }
        return currentBookmarks.contains { $0.pageKey == position.pageKey }
    }

    public func toggleBookmark() {
        guard let paper, let position = currentPosition else { return }
        if isCurrentPageBookmarked {
            state.bookmarks.removeAll { $0.paperID == paper.id && $0.pageKey == position.pageKey }
        } else {
            state.bookmarks.append(
                PageBookmark(
                    paperID: paper.id, pageKey: position.pageKey, pageIndex: position.pageIndex, mode: position.mode))
        }
        workspaceRevision += 1
        scheduleWorkspaceSave(immediately: true)
    }

    public func removeBookmark(_ id: UUID) {
        guard state.bookmarks.contains(where: { $0.id == id }) else { return }
        state.bookmarks.removeAll { $0.id == id }
        workspaceRevision += 1
        scheduleWorkspaceSave(immediately: true)
    }

    public func navigate(to bookmark: PageBookmark) {
        navigateToStablePage(bookmark.pageKey, paperID: bookmark.paperID)
    }

    public func navigate(to highlight: Highlight) {
        navigateToStablePage(highlight.pageKey, paperID: highlight.paperID)
    }

    public func navigateToPage(_ pageIndex: Int) {
        guard pageKeys.indices.contains(pageIndex) else { return }
        applyPosition(ReaderPosition(mode: mode, pageKey: pageKeys[pageIndex], pageIndex: pageIndex))
    }

    public func recordVisiblePage(_ pageIndex: Int) {
        guard pageKeys.indices.contains(pageIndex) else { return }
        visiblePage = pageIndex
        updateReadingPosition()
        scheduleWorkspaceSave()
    }

    public func changeMode(to requestedMode: String) {
        guard ["original", "reflow", "translated"].contains(requestedMode), requestedMode != mode,
            let paper, let current = currentPosition,
            let sourcePage = PaperPageLocator.sourcePage(for: current, in: paper, excluding: pendingArtifactIDs)
        else { return }
        let blockID = mode == "original" ? nil : activePages[safe: visiblePage]?.blockIDs.first
        navigateToSourcePage(sourcePage, blockID: blockID, preferredMode: requestedMode)
    }

    public func navigateToSourcePage(_ sourcePage: Int) {
        navigateToSourcePage(sourcePage, blockID: nil, preferredMode: mode)
    }

    public func searchInPaper(_ query: String) -> [PaperSearchResult] {
        guard let paper else { return [] }
        return PaperTextSearch.search(query, in: paper, excluding: pendingArtifactIDs)
    }

    public func navigate(to result: PaperSearchResult) {
        guard result.paperID == selectedPaperID else { return }
        navigateToSourcePage(
            result.sourcePage, blockID: result.blockID, preferredMode: result.isTranslation ? "translated" : mode)
    }

    public func loadNavigation() async {
        guard let paper else {
            navigationItems = []
            navigationLoading = false
            return
        }
        let request = UUID()
        navigationRequestID = request
        navigationLoading = true
        defer {
            if navigationRequestID == request { navigationLoading = false }
        }
        do {
            let items = try await outlineService.items(for: paper, root: root)
            guard !Task.isCancelled, selectedPaperID == paper.id, navigationRequestID == request else { return }
            navigationItems = items
        } catch is CancellationError {
            return
        } catch {
            guard selectedPaperID == paper.id, navigationRequestID == request else { return }
            navigationItems = PaperNavigationItem.pages(for: paper)
            status = error.localizedDescription
        }
    }

    /// Explicit flush for lifecycle boundaries and tests; scrolling normally uses the debounce below.
    public func flushReadingPosition() async {
        updateReadingPosition()
        workspaceSaveTask?.cancel()
        workspaceSaveTask = nil
        await saveWorkspaceIfNeeded()
    }

    func restoreWorkspace() {
        guard let paper else { return }
        var workspace = workspace(for: paper.id)
        let restored = workspace.position.flatMap {
            PaperPageLocator.resolve(pageKey: $0.pageKey, in: paper, excluding: pendingArtifactIDs)
        }
        let position: ReaderPosition?
        if workspace.position != nil && restored == nil {
            position = PaperPageLocator.position(sourcePage: 0, mode: "original", in: paper)
            status = "上次阅读页面暂不可用，已打开原文。"
        } else {
            position = restored ?? PaperPageLocator.initialPosition(in: paper, excluding: pendingArtifactIDs)
        }
        workspace.lastOpenedAt = Date()
        if workspace.status == .unread { workspace.status = .reading }
        workspace.position = position
        state.workspace[paper.id.uuidString] = workspace
        workspaceRevision += 1
        if let position {
            mode = position.mode
            visiblePage = position.pageIndex
            jumpPage = position.pageIndex
        }
        scheduleWorkspaceSave(immediately: true)
    }

    func updateReadingPosition() {
        guard let paper, let position = currentPosition else { return }
        var workspace = workspace(for: paper.id)
        guard workspace.position != position else { return }
        workspace.position = position
        state.workspace[paper.id.uuidString] = workspace
        workspaceRevision += 1
    }

    func scheduleWorkspaceSave(immediately: Bool = false) {
        guard loaded, workspaceRevision > savedWorkspaceRevision else { return }
        workspaceSaveTask?.cancel()
        workspaceSaveTask = Task { @MainActor [weak self] in
            if !immediately {
                do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            }
            guard !Task.isCancelled, let self else { return }
            await self.saveWorkspaceIfNeeded()
        }
    }

    private var currentPosition: ReaderPosition? {
        guard pageKeys.indices.contains(visiblePage) else { return nil }
        return ReaderPosition(mode: mode, pageKey: pageKeys[visiblePage], pageIndex: visiblePage)
    }

    private func saveWorkspaceIfNeeded() async {
        let revision = workspaceRevision
        guard loaded, revision > savedWorkspaceRevision else { return }
        if await save() { savedWorkspaceRevision = max(savedWorkspaceRevision, revision) }
    }

    private func applyPosition(_ position: ReaderPosition) {
        selectionText = ""
        selectionRects = []
        mode = position.mode
        visiblePage = position.pageIndex
        jumpPage = position.pageIndex
        updateReadingPosition()
        scheduleWorkspaceSave(immediately: true)
        touch()
    }

    private func navigateToStablePage(_ pageKey: String, paperID: UUID) {
        guard state.papers.contains(where: { $0.id == paperID }) else { return }
        if selectedPaperID != paperID { select(paperID) }
        guard let paper,
            let position = PaperPageLocator.resolve(pageKey: pageKey, in: paper, excluding: pendingArtifactIDs)
        else {
            message = "批注或书签对应的固定页面暂不可用，原始记录已保留。"
            return
        }
        applyPosition(position)
    }

    func navigateToSourcePage(_ sourcePage: Int, blockID: UUID?, preferredMode: String) {
        guard let paper else { return }
        if let position = PaperPageLocator.position(
            sourcePage: sourcePage, blockID: blockID, mode: preferredMode, in: paper, excluding: pendingArtifactIDs)
        {
            applyPosition(position)
        } else if let original = PaperPageLocator.position(sourcePage: sourcePage, mode: "original", in: paper) {
            applyPosition(original)
            status = "当前版式尚无此处内容，已定位到原文第 \(sourcePage + 1) 页。"
        }
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
