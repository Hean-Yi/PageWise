import PaperReaderKit
import SwiftUI

struct TopicShelvesView<SortMenu: View>: View {
    @Bindable var model: ReaderModel
    @Binding var selectedShelfID: UUID?
    var dragActive = false
    @ViewBuilder let sortMenu: SortMenu
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var overflows = false
    @State private var editing = false
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var saving = false
    @FocusState private var nameFocused: Bool
    @Namespace private var shelfSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if expanded {
                    ShelfRows { shelfItems }
                        .transition(.identity)
                } else {
                    scrollingShelves
                        .transition(.identity)
                }
                HStack(spacing: 0) {
                    sortMenu.padding(.trailing, 6)
                    if expanded || overflows {
                        Button {
                            withAnimation(ReaderMotion.disclosure(reduceMotion)) { expanded.toggle() }
                        } label: {
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                                .frame(width: shelfControlSize, height: shelfControlSize)
                                .contentShape(Rectangle())
                        }
                        .help(expanded ? "收起书架" : "展开全部书架")
                        .accessibilityLabel(expanded ? "收起书架" : "展开全部书架")
                    }
                    Button {
                        beginEditing(nil)
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: shelfControlSize, height: shelfControlSize)
                            .contentShape(Rectangle())
                    }
                    .help("新建书架").accessibilityLabel("新建书架").disabled(saving)
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                .foregroundStyle(ReaderTheme.muted)
                .frame(height: shelfControlSize)
                .fixedSize()
            }
            if editing {
                nameEditor
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(ReaderMotion.disclosure(reduceMotion), value: editing)
        .animation(ReaderMotion.disclosure(reduceMotion), value: selectedShelfID)
    }

    private var scrollingShelves: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(spacing: 4) { shelfItems }
            }
            .scrollIndicators(.hidden)
            .frame(height: shelfControlSize)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Compare against the room available without the disclosure to avoid a resize feedback loop.
                let available = geometry.containerSize.width + (overflows ? shelfControlSize : 0)
                return geometry.contentSize.width > available + 0.5
            } action: { _, overflow in
                overflows = overflow
            }
            .onChange(of: selectedShelfID, initial: true) { previous, selected in
                withAnimation(ReaderMotion.disclosure(reduceMotion || previous == selected)) {
                    if let selected { reader.scrollTo(selected) } else { reader.scrollTo("unclassified") }
                }
            }
        }
    }

    @ViewBuilder private var shelfItems: some View {
        let membership = model.state.paperShelfIDs.values
        let counts = membership.reduce(into: [UUID: Int]()) { $0[$1, default: 0] += 1 }
        shelfItem(name: "未分类论文", shelfID: nil, count: model.state.papers.count - membership.count)
            .id("unclassified")
        ForEach(model.state.shelves) { shelf in
            shelfItem(name: shelf.name, shelfID: shelf.id, count: counts[shelf.id, default: 0])
                .id(shelf.id)
                .contextMenu {
                    Button("打开书架") { selectedShelfID = shelf.id }
                    Button("改名") { beginEditing(shelf) }
                        .disabled(saving)
                    Button("删除书架", role: .destructive) {
                        Task {
                            if await model.deleteShelf(shelf.id), selectedShelfID == shelf.id {
                                selectedShelfID = nil
                            }
                        }
                    }.disabled(saving)
                }
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
                .textFieldStyle(.roundedBorder).focused($nameFocused)
                .onSubmit { saveName() }.disabled(saving)
                .frame(maxWidth: 280)
            Button(action: saveName) {
                Image(systemName: "checkmark").frame(width: 32, height: 32)
            }
            .foregroundStyle(ReaderTheme.accent)
            .help("保存书架名称").accessibilityLabel("保存书架名称")
            .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(action: cancelEditing) {
                Image(systemName: "xmark").frame(width: 32, height: 32)
            }
            .help("取消编辑").accessibilityLabel("取消编辑")
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
                if isUnclassified { Image(systemName: "tray").font(.system(size: 11)) }
                Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("\(count)").font(.system(size: 10)).monospacedDigit().fixedSize().foregroundStyle(
                    ReaderTheme.muted)
            }
            .foregroundStyle(selected || targeted ? ReaderTheme.accent : ReaderTheme.muted)
            .padding(.horizontal, 10).frame(height: 32)
            .background(
                ReaderTheme.accent.opacity(targeted ? 0.14 : selected ? 0.06 : 0),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(alignment: .bottom) {
                if selected {
                    Capsule().fill(ReaderTheme.accent).frame(width: 22, height: 2)
                        .matchedGeometryEffect(id: "selectedShelf", in: selection, properties: .position)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(ReaderTheme.accent.opacity(targeted ? 0.8 : 0), lineWidth: 1.5)
            }
            .frame(height: shelfControlSize)
            .scaleEffect(targeted && !reduceMotion ? 1.04 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).help(name)
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
