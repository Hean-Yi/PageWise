import PaperReaderKit
import SwiftUI

// Plain reference box avoids invalidating TopicShelvesView on every frame of sidebar resize while collapsed.
@MainActor private final class StripWidthBox {
    var width: CGFloat = 0
}

struct TopicShelvesView<SortMenu: View>: View {
    @Bindable var model: ReaderModel
    @Binding var selectedShelfID: UUID?
    var dragActive = false
    @ViewBuilder let sortMenu: SortMenu
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var stripWidth: CGFloat = 0
    @State private var measuredWidth = StripWidthBox()
    @State private var overflows = false
    @State private var editing = false
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var saving = false
    @State private var pendingDeleteShelf: (shelf: Shelf, count: Int)?
    @FocusState private var nameFocused: Bool
    @Namespace private var shelfSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                scrollingShelves
                HStack(spacing: 0) {
                    sortMenu.padding(.trailing, 6)
                    if expanded || overflows {
                        Button {
                            if !expanded { stripWidth = measuredWidth.width }
                            withAnimation(ReaderMotion.disclosure(reduceMotion)) { expanded.toggle() }
                        } label: {
                            ReaderIcon(.chevron, size: 14)
                                .rotationEffect(.degrees(expanded ? -90 : 90))
                                .frame(width: shelfControlSize, height: shelfControlSize)
                                .contentShape(Rectangle())
                        }
                        .readerIconButtonStyle(.plain).help(expanded ? "收起书架" : "展开全部书架")
                        .accessibilityLabel(expanded ? "收起书架" : "展开全部书架")
                    }
                    Button {
                        beginEditing(nil)
                    } label: {
                        ReaderIcon(.add, size: 16)
                            .frame(width: shelfControlSize, height: shelfControlSize)
                            .contentShape(Rectangle())
                    }
                    .readerIconButtonStyle(.plain)
                    .help("新建书架").accessibilityLabel("新建书架").disabled(saving)
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                .foregroundStyle(ReaderTheme.muted)
                .frame(height: shelfControlSize)
                .padding(.leading, 9)
                .readerGlassSurface(in: Capsule(), fallback: ReaderTheme.elevated)
                .fixedSize()
            }
            .readerGlassGroup()
            if editing {
                nameEditor
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(ReaderMotion.disclosure(reduceMotion), value: editing)
        .confirmationDialog(
            "删除书架「\(pendingDeleteShelf?.shelf.name ?? "")」？",
            isPresented: Binding(
                get: { pendingDeleteShelf != nil }, set: { if !$0 { pendingDeleteShelf = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除书架", role: .destructive) {
                guard let target = pendingDeleteShelf?.shelf else { return }
                pendingDeleteShelf = nil
                Task {
                    if await model.deleteShelf(target.id), selectedShelfID == target.id {
                        selectedShelfID = nil
                    }
                }
            }
            Button("取消", role: .cancel) { pendingDeleteShelf = nil }
        } message: {
            if let count = pendingDeleteShelf?.count, count > 0 {
                Text("书架内的 \(count) 篇论文将移回「未分类论文」，不会被删除。")
            }
        }
    }

    private var scrollingShelves: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                // Keep the same focusable buttons and native drop targets when they wrap.
                ShelfRows { shelfItems }
                    .frame(width: expanded && stripWidth > 0 ? stripWidth : nil, alignment: .leading)
                    .animation(ReaderMotion.navigation(reduceMotion), value: selectedShelfID)
            }
            .fixedSize(horizontal: false, vertical: true)
            .scrollIndicators(.hidden)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: { width in
                measuredWidth.width = width
                if expanded && abs(stripWidth - width) > 0.5 { stripWidth = width }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Compare against the room available without the disclosure to avoid a resize feedback loop.
                let available = geometry.containerSize.width + (overflows ? shelfControlSize : 0)
                return geometry.contentSize.width - available > 0.5
            } action: { _, next in
                if !expanded && overflows != next { overflows = next }
            }
            .onChange(of: selectedShelfID, initial: true) { previous, selected in
                // The first unclassified shelf already starts at the leading edge. Enqueuing
                // another scroll here can pull back a wheel gesture made during first layout.
                guard !expanded, previous != nil || selected != nil else { return }
                withAnimation(ReaderMotion.disclosure(reduceMotion || previous == selected)) {
                    reveal(selected, with: reader)
                }
            }
            .onChange(of: expanded) { _, expanded in
                if !expanded { reveal(selectedShelfID, with: reader) }
            }
        }
    }

    private func reveal(_ selected: UUID?, with reader: ScrollViewProxy) {
        if let selected { reader.scrollTo(selected) } else { reader.scrollTo("unclassified") }
    }

    @ViewBuilder private var shelfItems: some View {
        let membership = model.state.paperShelfIDs.values
        let counts = membership.reduce(into: [UUID: Int]()) { $0[$1, default: 0] += 1 }
        shelfItem(name: "未分类论文", shelfID: nil, count: model.state.papers.count - membership.count)
            .id("unclassified")
        ForEach(model.state.shelves) { shelf in
            shelfItem(name: shelf.name, shelfID: shelf.id, count: counts[shelf.id, default: 0])
                .id(shelf.id)
                .readerContextMenu(
                    shelf.name + "的选项",
                    items: [
                        .action("打开书架", icon: .library) { selectedShelfID = shelf.id },
                        .action("改名", icon: .annotation, enabled: !saving) { beginEditing(shelf) },
                        .divider,
                        .action("删除书架", icon: .delete, enabled: !saving, destructive: true) {
                            let count = counts[shelf.id, default: 0]
                            if count > 0 {
                                pendingDeleteShelf = (shelf, count)
                            } else {
                                Task {
                                    if await model.deleteShelf(shelf.id), selectedShelfID == shelf.id {
                                        selectedShelfID = nil
                                    }
                                }
                            }
                        },
                    ])
        }
    }

    private func shelfItem(name: String, shelfID: UUID?, count: Int) -> some View {
        TopicShelfItem(
            name: name, isUnclassified: shelfID == nil, count: count,
            selected: selectedShelfID == shelfID, dragActive: dragActive,
            selection: shelfSelection,
            select: { selectedShelfID = shelfID },
            accepts: { id in model.state.papers.contains { $0.id == id } },
            move: { PaperShelfDrag.receive($0, model: model, shelfID: shelfID) })
    }

    private var nameEditor: some View {
        HStack(spacing: 8) {
            TextField(editingID == nil ? "书架名称" : "新的书架名称", text: $name)
                .textFieldStyle(.plain).focused($nameFocused)
                .onSubmit { saveName() }.disabled(saving)
                .padding(.horizontal, 10).frame(height: 32)
                .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            nameFocused ? ReaderTheme.accent : ReaderTheme.line, lineWidth: nameFocused ? 1.5 : 1)
                )
                .frame(maxWidth: 280)
            Button(action: saveName) {
                ReaderActionSymbol("checkmark").frame(width: 32, height: 32)
            }
            .foregroundStyle(ReaderTheme.accent)
            .readerIconButtonStyle(.plain).help("保存书架名称").accessibilityLabel("保存书架名称")
            .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(action: cancelEditing) {
                ReaderIcon(.close, size: 14).frame(width: 32, height: 32)
            }
            .readerIconButtonStyle(.plain).help("取消编辑").accessibilityLabel("取消编辑")
            .keyboardShortcut(.cancelAction).disabled(saving)
            if saving { ProgressView().controlSize(.small) }
        }.buttonStyle(.plain).font(.system(size: 12))
    }

    private func beginEditing(_ shelf: Shelf?) {
        guard !saving else { return }
        editingID = shelf?.id
        name = shelf?.name ?? ""
        editing = true
        nameFocused = true
    }

    private func cancelEditing() {
        guard !saving else { return }
        editing = false
        nameFocused = false
    }

    private func saveName() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saving, !trimmedName.isEmpty else { return }
        saving = true
        let shelfID = editingID
        Task {
            let saved: Bool
            if let shelfID {
                saved = await model.renameShelf(shelfID, name: trimmedName)
            } else if let id = await model.createShelf(name: trimmedName) {
                selectedShelfID = id
                saved = true
            } else {
                saved = false
            }
            saving = false
            if saved { cancelEditing() }
        }
    }
}

private var shelfControlSize: CGFloat {
    #if os(macOS)
        36
    #else
        44
    #endif
}

/// Measures shelf buttons at their natural widths and moves whole buttons onto the next row.
struct ShelfRows: Layout {
    private let columnSpacing: CGFloat = 4
    private let rowSpacing: CGFloat = 2

    func makeCache(subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) -> CGSize {
        let width =
            proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? cache.reduce(0) { $0 + $1.width } + CGFloat(max(0, cache.count - 1)) * columnSpacing
        return CGSize(width: width, height: arrange(cache, width: width) { _, _ in })
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) {
        arrange(cache, width: bounds.width) { index, frame in
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    @discardableResult
    func arrange(_ sizes: [CGSize], width: CGFloat, place: (Int, CGRect) -> Void) -> CGFloat {
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            let itemWidth = min(size.width, width)
            if origin.x > 0 && origin.x + itemWidth > width {
                origin.x = 0
                origin.y += rowHeight + rowSpacing
                rowHeight = 0
            }
            place(index, CGRect(origin: origin, size: CGSize(width: itemWidth, height: size.height)))
            origin.x += itemWidth + columnSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return origin.y + rowHeight
    }
}

private struct TopicShelfItem: View {
    let name: String
    let isUnclassified: Bool
    let count: Int
    let selected: Bool
    let dragActive: Bool
    let selection: Namespace.ID
    let select: () -> Void
    let accepts: (UUID) -> Bool
    let move: ([NSItemProvider]) -> Bool
    @State private var targeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: select) {
            HStack(spacing: 7) {
                if isUnclassified { ReaderActionSymbol("tray").font(.system(size: 11)) }
                Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("\(count)").font(.system(size: 10)).monospacedDigit().fixedSize().foregroundStyle(
                    ReaderTheme.muted)
            }
            .foregroundStyle(selected || targeted ? ReaderTheme.accent : ReaderTheme.muted)
            .padding(.horizontal, 10).frame(height: 32)
            .background {
                if selected {
                    Color.clear
                        .readerGlassSurface(in: RoundedRectangle(cornerRadius: 8), fallback: ReaderTheme.elevated)
                        .overlay(alignment: .bottom) {
                            Capsule().fill(ReaderTheme.accent).frame(width: 20, height: 2)
                        }
                        .matchedGeometryEffect(id: "selectedShelf", in: selection)
                }
            }
            .background(ReaderTheme.accent.opacity(targeted ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(ReaderTheme.accent.opacity(targeted ? 0.8 : 0), lineWidth: 1.5)
            }
            .frame(height: shelfControlSize)
            .scaleEffect(targeted && !reduceMotion ? 1.04 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .readerIconButtonStyle(.plain).help(name)
        .accessibilityLabel("\(name)，\(count) 篇论文")
        .accessibilityAddTraits(selected ? .isSelected : [])
        #if os(macOS)
            .overlay {
                NativeShelfDrop(
                    activate: select, accepts: accepts,
                    receive: { id in move([PaperShelfDrag.provider(id)]) },
                    highlight: { targeted = $0 })
            }
        #else
            .onDrop(of: [PaperShelfDrag.typeIdentifier], isTargeted: $targeted, perform: move)
        #endif
        .animation(ReaderMotion.feedback(reduceMotion), value: targeted)
        .onChange(of: dragActive) { _, active in if !active { targeted = false } }
        .onChange(of: targeted) { _, value in
            ShelfDragDiagnostics.record(value ? "target-enter" : "target-exit")
        }
    }
}
