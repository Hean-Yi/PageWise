import PaperReaderKit
import SwiftUI

// Hover changes need no parent redraw. Read this value only at the start of a space gesture.
@MainActor private final class ShelfPointer {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var arrangement = CoverArrangement()
    private var sort: LibrarySort { model.state.preferredSort }
    @FocusState private var searchFocused: Bool
    @Namespace private var covers
    @State private var preview: ShelfPreviewTarget?
    @State private var pointer = ShelfPointer()

    private func showPreview(_ target: ShelfPreviewTarget) {
        guard preview == nil, arrangement.sourceID == nil else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) { preview = target }
    }

    @discardableResult private func dismissPreview() -> Bool {
        guard preview != nil else { return false }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { preview = nil }
        return true
    }

    private func releasePreview() -> Bool {
        if case .held = preview { return dismissPreview() }
        return false
    }

    private var papers: [Paper] {
        LibraryQuery.papers(in: model.state, collection: collection, query: query, sort: sort).filter {
            collection != .all || (selectedShelfID == nil && !query.isEmpty)
                || model.state.shelfID(for: $0.id) == selectedShelfID
        }
    }
    private var recent: Paper? {
        LibraryQuery.papers(in: model.state, collection: .reading).first {
            model.workspace(for: $0.id).position != nil
        }
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
                    if collection == .all && selectedShelfID == nil && query.isEmpty, let recent {
                        continueReading(recent).padding(.bottom, 22)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        if collection == .all {
                            TopicShelvesView(
                                model: model, selectedShelfID: $selectedShelfID, dragActive: arrangement.sourceID != nil
                            )
                        }
                        if !query.isEmpty && collection != .all {
                            Text("搜索结果").font(.callout).foregroundStyle(ReaderTheme.muted).frame(height: 44)
                        }
                        Spacer(minLength: 0)
                        sortMenu.frame(height: 44)
                    }
                    Rectangle().fill(ReaderTheme.line).frame(height: 1).padding(.bottom, 24)
                    if onlineSearch.isExpanded {
                        SearchView(search: onlineSearch, targetName: onlineTargetName)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                            .padding(.bottom, 26)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 32) {
                        if collection != .reading && collection != .finished {
                            AddPaperCover { onlineSearch.open(shelfID: collection == .all ? selectedShelfID : nil) }
                        }
                        ForEach(papers) { paper in
                            bookshelfItem(
                                paper, columns: count,
                                width: min(236, (available - CGFloat(count - 1) * 36) / CGFloat(count)))
                        }
                    }.padding(.top, 5)
                    if model.state.papers.isEmpty && collection == .all {
                        HStack(spacing: 14) {
                            Text("也可以拖入 PDF").foregroundStyle(ReaderTheme.muted)
                            Button("试读示例") { Task { await model.addDemo() } }
                                .buttonStyle(.plain).foregroundStyle(ReaderTheme.accent)
                        }.font(.system(size: 12)).padding(.top, 22)
                    } else if papers.isEmpty {
                        HStack {
                            Text(query.isEmpty ? "这个书架还没有论文" : "没有匹配的论文")
                                .foregroundStyle(ReaderTheme.muted)
                            if !query.isEmpty { Button("清除搜索") { query = "" }.buttonStyle(.plain) }
                        }.font(.system(size: 12)).padding(.top, 22)
                    }
                }.padding(.horizontal, inset).padding(.top, compact ? 24 : 32).padding(.bottom, 44)
            }
            .allowsHitTesting(preview == nil)
            .accessibilityHidden(preview != nil)
            .overlay {
                if let preview, let paper = model.state.papers.first(where: { $0.id == preview.paperID }) {
                    ShelfPaperPreview(paper: paper, model: model, covers: covers) {
                        dismissPreview()
                    } open: {
                        self.preview = nil
                        model.select(paper.id)
                    }
                    .id(paper.id)
                    .transition(.opacity)
                }
            }
            #if os(macOS)
                .background {
                    ShelfPreviewKeys(
                        hovered: { pointer.paperID },
                        press: { id in
                            guard preview == nil, arrangement.sourceID == nil else { return false }
                            showPreview(.held(id))
                            return true
                        }, release: releasePreview, dismiss: dismissPreview)
                }
            #endif
        }.onChange(of: query) { _, _ in arrangement.end() }
            .onChange(of: collection) { _, _ in
                arrangement.end()
                preview = nil
            }
            .onChange(of: selectedShelfID) { _, _ in
                arrangement.end()
                preview = nil
            }
            .onChange(of: sort) { _, _ in arrangement.end() }
            .onDisappear {
                arrangement.end()
                preview = nil
            }
            .onChange(of: findRequest) { _, _ in
                preview = nil
                searchFocused = true
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: onlineSearch.isExpanded)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selectedShelfID)
            .onChange(of: onlineSearch.isExpanded) { _, expanded in if expanded { searchFocused = false } }
            .onChange(of: model.state.shelves) { _, shelves in
                if let selectedShelfID, !shelves.contains(where: { $0.id == selectedShelfID }) {
                    self.selectedShelfID = nil
                }
            }
    }

    private func bookshelfItem(_ paper: Paper, columns: Int, width: CGFloat) -> some View {
        let ids = papers.map(\.id)
        let index = ids.firstIndex(of: paper.id) ?? 0
        let destination = index + arrangement.offset(for: paper.id)
        // Add-cover occupies the first grid cell but is never a reorder destination.
        let leading = collection != .reading && collection != .finished ? 1 : 0
        let from = index + leading
        let to = destination + leading
        let offset = CGSize(
            width: CGFloat(to % columns - from % columns) * (width + 36),
            height: CGFloat(to / columns - from / columns) * (width / 0.70 + 77))
        return BookshelfItem(
            model: model, paper: paper, covers: covers, previewed: preview?.paperID == paper.id,
            showPreview: showPreview, releasePreview: releasePreview,
            hoverCover: { pointer.update(paper.id, inside: $0) }, lifted: arrangement.sourceID == paper.id,
            arrangementOffset: offset,
            beginDrag: {
                arrangement.begin(paper.id, visible: ids, state: model.state, unfinishedFirst: collection == .all)
            },
            endDrag: { arrangement.end() },
            acceptsDrop: { arrangement.accepts($0, at: paper.id) },
            hoverDrop: { arrangement.hover($0, at: paper.id) },
            receiveDrop: { id in
                guard arrangement.accepts(id, at: paper.id), arrangement.reserveDrop() else { return false }
                Task { await arrangement.commit(model: model) }
                return true
            },
            moveEarlier: orderAction(paper.id, delta: -1),
            moveLater: orderAction(paper.id, delta: 1)
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: arrangement.preview)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: arrangement.sourceID)
    }

    private func orderAction(_ id: UUID, delta: Int) -> (() -> Void)? {
        let ids = papers.map(\.id)
        guard !arrangement.committing, let index = ids.firstIndex(of: id), ids.indices.contains(index + delta) else {
            return nil
        }
        let destination = ids[index + delta]
        if collection == .all {
            let finished = Set(LibraryQuery.papers(in: model.state, collection: .finished).map(\.id))
            guard finished.contains(id) == finished.contains(destination) else { return nil }
        }
        return {
            var reordered = ids
            reordered.swapAt(index, index + delta)
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
                .foregroundStyle(ReaderTheme.ink).accessibilityAddTraits(.isHeader)
            Text(
                "\(collection == .all && query.isEmpty ? model.state.papers.count : papers.count) 篇"
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
