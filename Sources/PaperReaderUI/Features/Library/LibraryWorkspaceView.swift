import PaperReaderKit
import SwiftUI

// Scrolling and hovering record the visible covers without invalidating the grid.
@MainActor private final class ShelfCoverLocations {
    var frames: [UUID: CGRect] = [:]
    var paperID: UUID?

    func update(_ id: UUID, inside: Bool) {
        if inside { paperID = id } else if paperID == id { paperID = nil }
    }
}

struct LibraryWorkspaceView: View {
    @Bindable var model: ReaderModel
    @Binding var collection: LibraryCollection
    @Binding var selectedShelfID: UUID?
    @Bindable var onlineSearch: OnlinePaperSearch
    let findRequest: Int
    @State private var query = ""

    var body: some View {
        ShelfWorkspaceContent(
            model: model, collection: $collection, selectedShelfID: $selectedShelfID, onlineSearch: onlineSearch,
            findRequest: findRequest, query: $query,
            listing: ShelfListing(state: model.state, collection: collection, query: query, shelfID: selectedShelfID))
    }
}

// Shelf membership, reading status and ordering only change with the library or its filters.
// Keeping this work outside the interactive view avoids sorting while lifting or returning a cover.
private struct ShelfListing {
    let entries: [(offset: Int, element: Paper)]
    let ids: [UUID]
    let firstFinishedIndex: Int?
    let recent: Paper?

    init(state: LibraryState, collection: LibraryCollection, query: String, shelfID: UUID?) {
        let sorted = LibraryQuery.papers(in: state, collection: collection, query: query, sort: state.preferredSort)
        let scoped = collection == .all && (shelfID != nil || query.isEmpty)
        let visible = scoped ? sorted.filter { state.shelfID(for: $0.id) == shelfID } : sorted
        entries = Array(visible.enumerated())
        ids = visible.map(\.id)
        firstFinishedIndex =
            collection == .all
            ? visible.firstIndex {
                LibraryCollection.finished.includes(state.workspace[$0.id.uuidString] ?? PaperWorkspace(), for: $0)
            } : nil
        if collection == .all, shelfID == nil, query.isEmpty {
            if state.preferredSort == .recent {
                recent = sorted.first {
                    guard let workspace = state.workspace[$0.id.uuidString], workspace.position != nil else {
                        return false
                    }
                    return LibraryCollection.reading.includes(workspace, for: $0)
                }
            } else {
                recent = LibraryQuery.papers(in: state, collection: .reading).first {
                    state.workspace[$0.id.uuidString]?.position != nil
                }
            }
        } else {
            recent = nil
        }
    }
}

private struct ShelfWorkspaceContent: View {
    @Bindable var model: ReaderModel
    @Binding var collection: LibraryCollection
    @Binding var selectedShelfID: UUID?
    @Bindable var onlineSearch: OnlinePaperSearch
    let findRequest: Int
    @Binding var query: String
    let listing: ShelfListing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrangement = CoverArrangement()
    private var sort: LibrarySort { model.state.preferredSort }
    @FocusState private var searchFocused: Bool
    private struct Preview {
        var target: ShelfPreviewTarget
        var flight: ShelfCoverFlight
    }
    @State private var preview: Preview?
    @State private var locations = ShelfCoverLocations()

    @discardableResult private func showPreview(_ target: ShelfPreviewTarget) -> Bool {
        guard arrangement.sourceID == nil, listing.ids.contains(target.paperID),
            let frame = locations.frames[target.paperID], !frame.isEmpty
        else {
            return false
        }
        if let preview {
            guard preview.target.paperID == target.paperID, preview.flight.returning else { return false }
            self.preview = Preview(target: target, flight: preview.flight.reversed(at: .now, landing: frame))
        } else {
            preview = Preview(target: target, flight: ShelfCoverFlight(onShelf: frame))
        }
        return true
    }

    @discardableResult private func dismissPreview() -> Bool {
        guard let preview else { return false }
        if preview.flight.awaitingLift || reduceMotion || locations.frames[preview.target.paperID] == nil {
            self.preview = nil
        } else if !preview.flight.returning, let frame = locations.frames[preview.target.paperID] {
            self.preview?.flight = preview.flight.reversed(at: .now, landing: frame)
        }
        return true
    }

    private func releasePreview() -> Bool {
        if case .held = preview?.target { return dismissPreview() }
        return false
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 650
            let inset: CGFloat = compact ? 22 : 42
            let available = max(150, geometry.size.width - inset * 2)
            let count = max(1, Int((available + 36) / 226))
            let columns = Array(
                repeating: GridItem(.flexible(minimum: 150, maximum: 236), spacing: 36, alignment: .top), count: count)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(compact: compact).padding(.bottom, compact ? 22 : 30)
                    if let recent = listing.recent {
                        continueReading(recent).padding(.bottom, 22)
                    }
                    if collection == .all {
                        TopicShelvesView(
                            model: model, selectedShelfID: $selectedShelfID, dragActive: arrangement.sourceID != nil
                        ) { sortMenu }
                    } else {
                        HStack(spacing: 12) {
                            if !query.isEmpty {
                                Text("搜索结果").font(.callout).foregroundStyle(ReaderTheme.muted)
                            }
                            Spacer(minLength: 0)
                            sortMenu
                        }.frame(height: 44)
                    }
                    Rectangle().fill(ReaderTheme.line).frame(height: 1).padding(.bottom, 24)
                    if onlineSearch.isExpanded {
                        SearchView(search: onlineSearch, targetName: onlineTargetName)
                            .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: -8)))
                            .padding(.bottom, 26)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 32) {
                        if collection != .reading && collection != .finished {
                            AddPaperCover { onlineSearch.open(shelfID: collection == .all ? selectedShelfID : nil) }
                                .quickStartTarget(onlineSearch.isExpanded ? nil : .discovery)
                        }
                        ForEach(listing.entries, id: \.element.id) { index, paper in
                            bookshelfItem(
                                paper, index: index, columns: count,
                                width: min(236, (available - CGFloat(count - 1) * 36) / CGFloat(count))
                            )
                            .transition(reduceMotion ? .identity : ReaderMotion.arrival(y: 5))
                        }
                    }.padding(.top, 5)
                        .animation(ReaderMotion.disclosure(reduceMotion), value: sort)
                    if model.state.papers.isEmpty && collection == .all {
                        HStack(spacing: 14) {
                            Text("也可以拖入 PDF").foregroundStyle(ReaderTheme.muted)
                            Button("试读示例") { Task { await model.addDemo() } }
                                .buttonStyle(.plain).foregroundStyle(ReaderTheme.accent)
                        }.font(.system(size: 12)).padding(.top, 22)
                    } else if listing.entries.isEmpty {
                        HStack {
                            Text(query.isEmpty ? "这个书架还没有论文" : "没有匹配的论文")
                                .foregroundStyle(ReaderTheme.muted)
                            if !query.isEmpty { Button("清除搜索") { query = "" }.buttonStyle(.plain) }
                        }.font(.system(size: 12)).padding(.top, 22)
                    }
                }.padding(.horizontal, inset).padding(.top, compact ? 24 : 32).padding(.bottom, 44)
                    .animation(ReaderMotion.disclosure(reduceMotion), value: onlineSearch.isExpanded)
                    .animation(ReaderMotion.disclosure(reduceMotion), value: selectedShelfID)
                    .animation(ReaderMotion.navigation(reduceMotion), value: collection)
            }
            .allowsHitTesting(preview == nil)
            .accessibilityHidden(preview != nil)
            .overlay {
                if let preview, let paper = model.state.papers.first(where: { $0.id == preview.target.paperID }) {
                    ShelfPaperPreview(paper: paper, model: model, flight: preview.flight) {
                        if self.preview?.flight == preview.flight, preview.flight.awaitingLift {
                            self.preview?.flight = preview.flight.lifted(at: .now)
                        }
                    } dismiss: {
                        dismissPreview()
                    } landed: {
                        if self.preview?.flight == preview.flight { self.preview = nil }
                    } open: {
                        self.preview = nil
                        model.select(paper.id)
                    }
                    .id(paper.id)
                    .transition(.identity)
                }
            }
            #if os(macOS)
                .background {
                    ShelfPreviewKeys(
                        selectedShelfID: selectedShelfID,
                        hovered: { point in
                            listing.ids.first { locations.frames[$0]?.contains(point) == true } ?? locations.paperID
                                ?? (preview?.flight.returning == true ? preview?.target.paperID : nil)
                        },
                        press: { showPreview(.held($0)) }, release: releasePreview, dismiss: dismissPreview)
                }
            #endif
        }.coordinateSpace(.named(ShelfCoverFlight.coordinateSpace))
            .onChange(of: query) { _, _ in arrangement.end() }
            .onChange(of: collection) { _, _ in
                arrangement.end()
                preview = nil
            }
            .onChange(of: selectedShelfID) { _, _ in
                arrangement.end()
                preview = nil
            }
            .onChange(of: sort) { _, _ in arrangement.end() }
            .onChange(of: listing.ids) { _, ids in
                if let preview, !ids.contains(preview.target.paperID) { self.preview = nil }
                if arrangement.sourceID != nil { arrangement.end() }
            }
            .onDisappear {
                arrangement.end()
                preview = nil
            }
            .onChange(of: findRequest) { _, _ in
                preview = nil
                searchFocused = true
            }
            .onChange(of: onlineSearch.isExpanded) { _, expanded in if expanded { searchFocused = false } }
            .onChange(of: model.state.shelves, initial: true) { _, shelves in
                if let selectedShelfID, !shelves.contains(where: { $0.id == selectedShelfID }) {
                    self.selectedShelfID = nil
                }
            }
    }

    private func bookshelfItem(_ paper: Paper, index: Int, columns: Int, width: CGFloat) -> some View {
        let destination = index + arrangement.offset(for: paper.id)
        // Add-cover occupies the first grid cell but is never a reorder destination.
        let leading = collection != .reading && collection != .finished ? 1 : 0
        let from = index + leading
        let to = destination + leading
        let offset = CGSize(
            width: CGFloat(to % columns - from % columns) * (width + 36),
            height: CGFloat(to / columns - from / columns) * (width / 0.70 + 77))
        return BookshelfItem(
            model: model, paper: paper, recordFrame: { locations.frames[paper.id] = $0 },
            previewed: preview?.target.paperID == paper.id && preview?.flight.awaitingLift == false,
            showPreview: { showPreview($0) }, releasePreview: releasePreview,
            hoverCover: { locations.update(paper.id, inside: $0) }, lifted: arrangement.sourceID == paper.id,
            arrangementOffset: offset,
            beginDrag: {
                arrangement.begin(
                    paper.id, visible: listing.ids, state: model.state, unfinishedFirst: collection == .all)
            },
            endDrag: { arrangement.end() },
            acceptsDrop: { arrangement.accepts($0, at: paper.id) },
            hoverDrop: { arrangement.hover($0, at: paper.id) },
            receiveDrop: { id in
                guard arrangement.accepts(id, at: paper.id), arrangement.reserveDrop() else { return false }
                Task { await arrangement.commit(model: model) }
                return true
            },
            moveEarlier: orderAction(at: index, delta: -1),
            moveLater: orderAction(at: index, delta: 1)
        )
        .animation(ReaderMotion.disclosure(reduceMotion), value: arrangement.preview)
        .animation(ReaderMotion.feedback(reduceMotion), value: arrangement.sourceID)
    }

    private func orderAction(at index: Int, delta: Int) -> (() -> Void)? {
        let ids = listing.ids
        let destination = index + delta
        guard !arrangement.committing, ids.indices.contains(destination) else { return nil }
        if let boundary = listing.firstFinishedIndex, (index < boundary) != (destination < boundary) { return nil }
        return {
            var reordered = ids
            reordered.swapAt(index, destination)
            Task { await model.arrangePapers(original: ids, reordered: reordered, unfinishedFirst: collection == .all) }
        }
    }

    private var onlineTargetName: String {
        guard let id = onlineSearch.targetShelfID else { return "未分类论文" }
        return model.state.shelves.first { $0.id == id }?.name ?? "原书架已删除"
    }

    @ViewBuilder private func header(compact: Bool) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 20) {
                heading
                searchField
            }
        } else {
            HStack(alignment: .center) {
                heading
                Spacer(minLength: 24)
                searchField.frame(width: 250)
            }
        }
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(collection.title).font(ReaderTheme.editorial(36))
                .contentTransition(reduceMotion ? .identity : .opacity)
                .foregroundStyle(ReaderTheme.ink).accessibilityAddTraits(.isHeader)
            Text(
                "\(collection == .all && query.isEmpty ? model.state.papers.count : listing.entries.count) 篇"
            ).font(.callout).foregroundStyle(ReaderTheme.muted)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(ReaderTheme.muted)
            TextField("搜索书库", text: $query).textFieldStyle(.plain).focused($searchFocused)
                .accessibilityLabel("搜索书库")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(ReaderTheme.muted)
                .help("清除搜索").accessibilityLabel("清除搜索")
            } else {
                #if os(macOS)
                    Text("⌘ F").font(.system(size: 10)).foregroundStyle(ReaderTheme.muted)
                #endif
            }
        }.font(.callout).padding(.horizontal, 12).frame(minHeight: 36)
            .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(searchFocused ? ReaderTheme.accent : ReaderTheme.line)
                    .animation(ReaderMotion.feedback(reduceMotion), value: searchFocused)
                    .allowsHitTesting(false)
            }
    }

    private func continueReading(_ paper: Paper) -> some View {
        Button {
            model.select(paper.id)
        } label: {
            HStack(spacing: 16) {
                BookCoverView(paper: paper).frame(width: 42)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("继续阅读").font(.caption.weight(.semibold)).foregroundStyle(ReaderTheme.accent)
                        if let position = model.workspace(for: paper.id).position {
                            Text(positionLabel(position, in: paper)).font(.caption).foregroundStyle(ReaderTheme.muted)
                        }
                    }
                    Text(paper.title).font(ReaderTheme.editorial(20, weight: .medium))
                        .foregroundStyle(ReaderTheme.ink).lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").font(.system(size: 15, weight: .regular))
                    .foregroundStyle(ReaderTheme.accent).frame(width: 34, height: 34)
            }.padding(.horizontal, 18).padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(ReaderTheme.line) }
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityLabel("继续阅读 \(paper.title)")
    }

    private func positionLabel(_ position: ReaderPosition, in paper: Paper) -> String {
        let isSection =
            paper.htmlReading?.sections.contains { $0.id.uuidString == position.pageKey } == true
            || paper.retainedReadings?.contains { version in
                version.html?.sections.contains { $0.id.uuidString == position.pageKey } == true
            } == true
        return "\(readingModeTitle(position.mode)) · 第 \(position.pageIndex + 1) \(isSection ? "段" : "页")"
    }

    private var sortMenu: some View {
        Menu {
            Picker(
                "排序",
                selection: Binding(
                    get: { sort },
                    set: { value in Task { await model.selectLibrarySort(value) } })
            ) {
                ForEach(LibrarySort.allCases) { item in Text(item.title).tag(item) }
            }.pickerStyle(.inline).labelsHidden()
        } label: {
            Label(sort.title, systemImage: "arrow.up.arrow.down").font(.caption)
        }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(ReaderTheme.muted)
    }
}

func readingModeTitle(_ mode: String) -> String {
    switch mode {
    case "original": "原文"
    case "translated": "双语"
    default: "重排"
    }
}
