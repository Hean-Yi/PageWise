import Foundation
import PaperReaderKit

extension ReaderModel {
    public func workspace(for paperID: UUID) -> PaperWorkspace {
        state.workspace[paperID.uuidString] ?? PaperWorkspace()
    }

    public func setReadingStatus(_ status: PaperReadingStatus, for paperID: UUID) {
        guard let paper = state.papers.first(where: { $0.id == paperID }) else { return }
        var workspace = workspace(for: paperID)
        let previous = workspace
        workspace.status = status
        workspace.status = ReadingProgress.resolve(paper: paper, workspace: workspace).readingStatus
        guard workspace != previous else { return }
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
        guard let version = highlight.contentVersion else {
            navigateToStablePage(highlight.pageKey, paperID: highlight.paperID)
            return
        }
        guard let current = state.papers.first(where: { $0.id == highlight.paperID }) else { return }
        if let key = UUID(uuidString: highlight.pageKey), !pendingArtifactIDs.contains(key),
            let position = current.htmlPosition(version: version, pageKeys: [highlight.pageKey])
        {
            if selectedPaperID != current.id || selectedSection != "library" { select(current.id) }
            retainedReadingID = position.editionID
            mode = "translated"
            navigateToPage(position.index)
            return
        }
        message = "无法在这处标画对应的阅读版本中找到原文。"
    }

    /// Resolve a saved citation before changing the reader. The PDF is immutable and source
    /// blocks without a verified PDF page can also belong to a retained reading edition.
    func evidencePageKey(for evidence: Evidence) -> String? {
        guard let id = evidence.paperID, !pendingImportIDs.contains(id),
            let document = state.papers.first(where: { $0.id == id })
        else { return nil }
        if let index = evidence.sourcePage, index >= 0, index < document.pageCount {
            return "original-\(index)"
        }
        guard let blockID = evidence.blockID else { return nil }
        func matchingPage(in pages: [PageArtifact]) -> String? {
            pages.first { !pendingArtifactIDs.contains($0.id) && $0.blockIDs.contains(blockID) }?.id.uuidString
        }
        if selectedPaperID == id, retainedReadingID != nil, let paper,
            let key = matchingPage(in: paper.readingPages)
        {
            return key
        }
        if document.canReflow,
            let key = matchingPage(in: document.readingPages) ?? matchingPage(in: document.previewPages)
        {
            return key
        }
        for retained in document.retainedReadings ?? [] {
            if let key = matchingPage(in: retained.readingPages) { return key }
        }
        return nil
    }

    @discardableResult
    public func jump(to evidence: Evidence) -> Bool {
        guard let paperID = evidence.paperID, let key = evidencePageKey(for: evidence) else { return false }
        if key.hasPrefix("original-") { pdfBilingual.close() }
        navigateToStablePage(key, paperID: paperID)
        return selectedPaperID == paperID && pageKeys[safe: visiblePage] == key
    }

    public func navigateToPage(_ pageIndex: Int) {
        guard pageKeys.indices.contains(pageIndex) else { return }
        applyPosition(ReaderPosition(mode: mode, pageKey: pageKeys[pageIndex], pageIndex: pageIndex))
    }

    public func recordVisiblePage(_ pageIndex: Int) {
        guard pageKeys.indices.contains(pageIndex) else { return }
        if pageIndex != visiblePage { invalidateSearchNavigation() }
        visiblePage = pageIndex
        updateReadingPosition()
        scheduleWorkspaceSave()
    }

    public func changeMode(to requestedMode: String) {
        guard ["original", "reflow", "translated"].contains(requestedMode), requestedMode != mode,
            let paper, let current = currentPosition
        else { return }
        let sourcePage = PaperPageLocator.sourcePage(for: current, in: paper, excluding: pendingArtifactIDs)
        if sourcePage == nil {
            if requestedMode == "original",
                let position = PaperPageLocator.position(sourcePage: 0, mode: "original", in: paper)
            {
                applyPosition(position)
                status = "此处尚未匹配原文页码，已打开原版首页，请核对位置。"
            }
            return
        }
        let blockID = mode == "original" ? nil : activePages[safe: visiblePage]?.blockIDs.first
        if requestedMode == "translated",
            PaperPageLocator.position(sourcePage: sourcePage!, blockID: blockID, mode: requestedMode, in: paper) == nil,
            let first = paper.readingPages.first,
            let position = PaperPageLocator.resolve(pageKey: first.id.uuidString, in: paper)
        {
            applyPosition(position)
            status = "此处尚无对应重排页，已打开已完成的双语首页。"
        } else {
            navigateToSourcePage(sourcePage!, blockID: blockID, preferredMode: requestedMode)
        }
    }

    public func navigateToSourcePage(_ sourcePage: Int) {
        navigateToSourcePage(sourcePage, blockID: nil, preferredMode: mode)
    }

    public func searchInPaper(_ query: String) -> [PaperSearchResult] {
        guard let paper else { return [] }
        return PaperTextSearch.search(query, in: paper, excluding: pendingArtifactIDs)
    }

    public func navigate(to result: PaperSearchResult) {
        guard result.paperID == selectedPaperID, let paper else { return }
        invalidateSearchNavigation()
        let targetMode = result.isTranslation || result.sourcePage < 0 ? "translated" : mode
        let pages = targetMode == "translated" ? paper.readingPages : paper.previewPages
        let candidates = pages.filter { page in
            !pendingArtifactIDs.contains(page.id)
                && (result.blockID.map { page.blockIDs.contains($0) } ?? (page.sourcePage == result.sourcePage))
        }
        guard targetMode != "original", candidates.count > 1 else {
            navigateToSourcePage(result.sourcePage, blockID: result.blockID, preferredMode: targetMode)
            return
        }
        if result.hasAmbiguousTranslationContext && result.sourcePage >= 0 {
            navigateToSourcePage(result.sourcePage, blockID: nil, preferredMode: "original")
            status = "原文与译文的定位上下文相同，无法区分匹配位置，已打开原文第 \(result.sourcePage + 1) 页。"
            return
        }
        let request = UUID()
        let startingMode = mode
        let locator = pageTextLocator
        let root = root
        searchNavigationRequestID = request
        searchNavigationTask = Task { @MainActor [weak self] in
            let pageKey: String?
            let failed: Bool
            do {
                let locatorText = result.isTranslation ? result.matchingContext : result.matchedText
                pageKey = try await locator.pageKey(matching: locatorText, in: candidates, root: root)
                failed = false
            } catch is CancellationError {
                return
            } catch {
                pageKey = nil
                failed = true
            }
            guard let self, !Task.isCancelled, self.searchNavigationRequestID == request,
                self.selectedPaperID == result.paperID, self.mode == startingMode,
                self.selectedSection == "library", self.isActive
            else { return }
            self.searchNavigationRequestID = nil
            self.searchNavigationTask = nil
            self.applySearchDestination(pageKey, result: result, targetMode: targetMode, failed: failed)
        }
    }

    func invalidateSearchNavigation() {
        searchNavigationRequestID = nil
        searchNavigationTask?.cancel()
        searchNavigationTask = nil
    }

    public var navigationDocumentID: String? {
        guard let paper else { return nil }
        if usesHTMLReading, let html = paper.htmlReading { return paper.id.uuidString + "/" + html.relativePath }
        return paper.id.uuidString
    }

    public var displayedNavigationItems: [PaperNavigationItem] {
        loadedNavigationDocumentID == navigationDocumentID ? navigationItems : []
    }

    public func navigationIndex(for item: PaperNavigationItem) -> Int? {
        if let id = item.readingSectionID {
            return usesHTMLReading ? activePages.firstIndex(where: { $0.id == id }) : nil
        }
        return item.sourcePage >= 0 ? item.sourcePage : nil
    }

    public func navigate(to item: PaperNavigationItem) {
        guard displayedNavigationItems.contains(where: { $0.id == item.id }), let index = navigationIndex(for: item)
        else { return }
        if item.readingSectionID != nil {
            navigateToPage(index)
        } else {
            navigateToSourcePage(index)
            if mode == "original", jumpPage == item.sourcePage { jumpOutlineItem = item }
        }
    }

    public func loadNavigation() async {
        guard let paper, let documentID = navigationDocumentID else {
            loadedNavigationDocumentID = nil
            navigationItems = []
            navigationLoading = false
            return
        }
        guard loadedNavigationDocumentID != documentID else { return }
        let request = UUID()
        let html = usesHTMLReading ? paper.htmlReading : nil
        navigationRequestID = request
        navigationLoading = true
        defer {
            if navigationRequestID == request { navigationLoading = false }
        }
        do {
            let items: [PaperNavigationItem]
            if let html {
                items = try await HTMLReadingStore().navigationItems(for: html, root: root)
            } else {
                items = try await outlineService.items(for: paper, root: root)
            }
            guard !Task.isCancelled, navigationDocumentID == documentID, navigationRequestID == request else { return }
            navigationItems = items
            loadedNavigationDocumentID = documentID
        } catch is CancellationError {
            return
        } catch {
            guard navigationDocumentID == documentID, navigationRequestID == request else { return }
            navigationItems = html == nil ? PaperNavigationItem.pages(for: paper) : []
            loadedNavigationDocumentID = documentID
            status = error.localizedDescription
        }
    }

    /// Explicit flush for lifecycle boundaries and tests; scrolling normally uses the debounce below.
    public func flushReadingPosition() async {
        _ = await highlightSaveTask?.value
        await flushReadingNotes()
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
        if workspace.status == .unread {
            var started = workspace
            started.status = .reading
            // Reopening an explicitly unread paper must not reactivate its saved completion.
            if ReadingProgress.resolve(paper: paper, workspace: started) != .finished {
                workspace.status = .reading
            }
        } else {
            workspace.status = ReadingProgress.resolve(paper: paper, workspace: workspace).readingStatus
        }
        workspace.position = position
        workspace.status = ReadingProgress.resolve(paper: paper, workspace: workspace).readingStatus
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
        let previous = workspace
        workspace.status = ReadingProgress.resolve(paper: paper, workspace: workspace).readingStatus
        if workspace.status == .unread {
            let previousPage = workspace.position.flatMap { PaperPageLocator.sourcePage(for: $0, in: paper) }
            let currentPage = PaperPageLocator.sourcePage(for: position, in: paper)
            if previousPage != currentPage { workspace.status = .reading }
        }
        workspace.position = position
        workspace.status = ReadingProgress.resolve(paper: paper, workspace: workspace).readingStatus
        guard workspace != previous else { return }
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
        invalidateSearchNavigation()
        selectionText = ""
        selectionRects = []
        mode = position.mode
        visiblePage = position.pageIndex
        jumpPage = position.pageIndex
        updateReadingPosition()
        scheduleWorkspaceSave(immediately: true)
        touch()
    }

    private func applySearchDestination(
        _ pageKey: String?, result: PaperSearchResult, targetMode: String, failed: Bool
    ) {
        guard let paper else { return }
        if let pageKey,
            let position = PaperPageLocator.resolve(pageKey: pageKey, in: paper, excluding: pendingArtifactIDs),
            position.mode == targetMode
        {
            applyPosition(position)
        } else if let original = PaperPageLocator.position(sourcePage: result.sourcePage, mode: "original", in: paper) {
            applyPosition(original)
            let reason = failed ? "固定页面暂无法读取" : "未能在固定页中定位匹配文字"
            status = "\(reason)，已打开原文第 \(result.sourcePage + 1) 页。"
        } else {
            status = "无法精确定位此处；原文页码尚未核对，请查看原版。"
        }
    }

    private func navigateToStablePage(_ pageKey: String, paperID: UUID) {
        guard state.papers.contains(where: { $0.id == paperID }) else { return }
        if selectedPaperID != paperID || selectedSection != "library" { select(paperID) }
        if let current = state.papers.first(where: { $0.id == paperID }) {
            retainedReadingID =
                current.readingPages.contains(where: { $0.id.uuidString == pageKey })
                ? nil
                : current.retainedReadings?.first(where: { $0.readingPages.contains { $0.id.uuidString == pageKey } })?
                    .id
        }
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
