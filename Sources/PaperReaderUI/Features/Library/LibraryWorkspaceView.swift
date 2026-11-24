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

struct ShelfSearchReveal: Identifiable {
    let id = UUID()
    let paperID: UUID
    let shelfID: UUID?

    init?(paperID: UUID, in state: LibraryState) {
        guard state.papers.contains(where: { $0.id == paperID }) else { return nil }
        self.paperID = paperID
        shelfID = state.shelfID(for: paperID)
    }
}

struct LibraryWorkspaceView: View {
    @Bindable var model: ReaderModel
    @Binding var collection: LibraryCollection
    @Binding var selectedShelfID: UUID?
    @Bindable var onlineSearch: OnlinePaperSearch
    let findRequest: Int
    let openSample: () -> Void

    var body: some View {
        ShelfWorkspaceContent(
            model: model, collection: $collection, selectedShelfID: $selectedShelfID, onlineSearch: onlineSearch,
            findRequest: findRequest, openSample: openSample,
            listing: ShelfListing(state: model.state, collection: collection, shelfID: selectedShelfID))
    }
}

// Shelf membership, reading status and ordering only change with the library or its filters.
// Keeping this work outside the interactive view avoids sorting while lifting or returning a cover.
private struct ShelfListing {
    let entries: [(offset: Int, element: Paper)]
    let ids: [UUID]
    let firstFinishedIndex: Int?
    let recent: Paper?

    init(state: LibraryState, collection: LibraryCollection, shelfID: UUID?) {
        let sorted = LibraryQuery.papers(in: state, collection: collection, sort: state.preferredSort)
        let visible = collection == .all ? sorted.filter { state.shelfID(for: $0.id) == shelfID } : sorted
        entries = Array(visible.enumerated())
        ids = visible.map(\.id)
        firstFinishedIndex =
            collection == .all
            ? visible.firstIndex {
                LibraryCollection.finished.includes(state.workspace[$0.id.uuidString] ?? PaperWorkspace(), for: $0)
            } : nil
        recent = LibraryQuery.lastOpenedPaper(in: state)
    }
}

private struct ShelfWorkspaceContent: View {
    @Bindable var model: ReaderModel
    @Binding var collection: LibraryCollection
    @Binding var selectedShelfID: UUID?
    @Bindable var onlineSearch: OnlinePaperSearch
    let findRequest: Int
    let openSample: () -> Void
    let listing: ShelfListing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrangement = CoverArrangement()
    private var sort: LibrarySort { model.state.preferredSort }
    @State private var searchReveal: ShelfSearchReveal?
    @State private var dismissSearchRequest = 0
    private enum ScrollTarget: Hashable {
        case header
        case paper(UUID)
    }
    private struct Preview {
        var target: ShelfPreviewTarget
        var flight: ShelfCoverFlight
    }
    @State private var preview: Preview?
    @State private var locations = ShelfCoverLocations()
    @State private var arrivalFromTrailing = false
    private struct ShelfSelection: Equatable {
        let collection: LibraryCollection
        let shelfID: UUID?
    }

    private var selection: ShelfSelection {
        ShelfSelection(collection: collection, shelfID: collection == .all ? selectedShelfID : nil)
    }

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
        ScrollViewReader { scroll in
            workspace
                .librarySearchSuggestions(
                    state: model.state, findRequest: findRequest, dismissRequest: dismissSearchRequest
                ) { paperID in
                    guard let target = ShelfSearchReveal(paperID: paperID, in: model.state) else { return }
                    collection = .all
                    selectedShelfID = target.shelfID
                    searchReveal = target
                }
                .task(id: searchReveal?.id) {
                    guard let target = searchReveal else { return }
                    withAnimation(ReaderMotion.navigation(reduceMotion)) {
                        scroll.scrollTo(ScrollTarget.paper(target.paperID))
                    }
                    try? await Task.sleep(for: .seconds(2))
                    if searchReveal?.id == target.id { searchReveal = nil }
                }
                .onChange(of: findRequest) { _, _ in
                    preview = nil
                    scroll.scrollTo(ScrollTarget.header, anchor: .top)
                }
        }
    }

    private var workspace: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 650
            let inset: CGFloat = compact ? 22 : 42
            let available = max(150, geometry.size.width - inset * 2)
            let count = max(1, Int((available + 36) / 226))
            let columns = Array(
                repeating: GridItem(.flexible(minimum: 150, maximum: 236), spacing: 36, alignment: .top), count: count)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(compact: compact).padding(.bottom, compact ? 22 : 30).id(ScrollTarget.header)
                    if let recent = listing.recent {
                        continueReading(recent)
                            .scrollTransition(
                                topLeading: reduceMotion ? .identity : .interactive,
                                bottomTrailing: .identity, axis: .vertical
                            ) { card, phase in
                                card.opacity(phase.isIdentity ? 1 : 0.55)
                                    .offset(y: phase.isIdentity ? 0 : -4)
                            }
                            .padding(.bottom, 18)
                    }
                    if collection == .all {
                        TopicShelvesView(
                            model: model, selectedShelfID: $selectedShelfID, dragActive: arrangement.sourceID != nil
                        ) { sortMenu }
                    } else {
                        HStack {
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
                            .id(ScrollTarget.paper(paper.id))
                            .transition(reduceMotion ? .identity : ReaderMotion.arrival(y: 5))
                        }
                    }.padding(.top, 5)
                        .animation(ReaderMotion.disclosure(reduceMotion), value: sort)
                        .transaction(value: selection) {
                            $0.animation = nil
                            $0.disablesAnimations = true
                        }
                        .keyframeAnimator(initialValue: ShelfBookArrival.duration, trigger: selection) {
                            [reduceMotion] grid, time in
                            grid.environment(\.shelfArrivalTime, reduceMotion ? ShelfBookArrival.duration : time)
                        } keyframes: { _ in
                            if reduceMotion {
                                MoveKeyframe(ShelfBookArrival.duration)
                            } else {
                                MoveKeyframe(0)
                                LinearKeyframe(ShelfBookArrival.duration, duration: ShelfBookArrival.duration)
                            }
                        }
                    if model.state.papers.isEmpty && collection == .all {
                        HStack(spacing: 14) {
                            Text("也可以拖入 PDF").foregroundStyle(ReaderTheme.muted)
                            Button("试读内置示例", action: openSample)
                                .disabled(model.isImporting)
                                .buttonStyle(.plain).foregroundStyle(ReaderTheme.accent)
                        }.font(.system(size: 12)).padding(.top, 22)
                    } else if listing.entries.isEmpty {
                        Text("这个书架还没有论文").foregroundStyle(ReaderTheme.muted)
                            .font(.system(size: 12)).padding(.top, 22)
                    }
                }.padding(.horizontal, inset).padding(.top, compact ? 24 : 32).padding(.bottom, 44)
                    .animation(ReaderMotion.disclosure(reduceMotion), value: onlineSearch.isExpanded)
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
            .onChange(of: selection) { previous, selected in
                if previous.collection == selected.collection {
                    let shelves = model.state.shelves
                    let from = shelves.firstIndex { $0.id == previous.shelfID } ?? -1
                    let to = shelves.firstIndex { $0.id == selected.shelfID } ?? -1
                    arrivalFromTrailing = to < from
                } else {
                    let categories = LibraryCollection.allCases
                    let from = categories.firstIndex(of: previous.collection) ?? 0
                    let to = categories.firstIndex(of: selected.collection) ?? 0
                    arrivalFromTrailing = to < from
                }
                dismissSearchRequest += 1
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
            .onChange(of: onlineSearch.isExpanded) { _, expanded in if expanded { dismissSearchRequest += 1 } }
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
            model: model, paper: paper,
            arrival: ShelfBookArrival(position: from, columns: columns, fromTrailing: arrivalFromTrailing),
            recordFrame: { locations.frames[paper.id] = $0 },
            searchLocated: searchReveal?.paperID == paper.id,
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
                LibrarySearchField()
            }
        } else {
            HStack(alignment: .center) {
                heading
                Spacer(minLength: 24)
                LibrarySearchField().frame(width: 250)
            }
        }
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(collection.title).font(ReaderTheme.editorial(36))
                .contentTransition(reduceMotion ? .identity : .opacity)
                .foregroundStyle(ReaderTheme.ink).accessibilityAddTraits(.isHeader)
            Text(
                "\(collection == .all ? model.state.papers.count : listing.entries.count) 篇"
            ).font(.callout).foregroundStyle(ReaderTheme.muted)
        }
    }

    private func continueReading(_ paper: Paper) -> some View {
        Button {
            model.select(paper.id)
        } label: {
            HStack(spacing: 16) {
                BookCoverView(paper: paper).frame(width: 34)
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
                ReaderIcon(.openNote, size: 18)
                    .foregroundStyle(ReaderTheme.accent).frame(width: 34, height: 34)
            }.padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(ReaderTheme.line) }
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.readerIconButtonStyle(.plain).accessibilityLabel("继续阅读 \(paper.title)")
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
            Label(sort.title, systemImage: "arrow.up.arrow.down").labelStyle(ReaderSymbolLabelStyle()).font(.caption)
        }.readerMenuIconInteraction().fixedSize().foregroundStyle(ReaderTheme.muted)
    }
}

func readingModeTitle(_ mode: String) -> String {
    switch mode {
    case "original": "原文"
    case "translated": "双语"
    default: "重排"
    }
}
