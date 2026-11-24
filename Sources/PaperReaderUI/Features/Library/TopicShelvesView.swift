import PaperReaderKit
import SwiftUI

struct TopicShelvesView: View {
    @Bindable var model: ReaderModel
    @Binding var selectedShelfID: UUID?
    var dragActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editing = false
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var saving = false
    @State private var scrollTargetID: ShelfScrollTarget? = .unclassified
    @FocusState private var nameFocused: Bool
    @Namespace private var shelfSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    shelfItem(name: "未分类论文", icon: "tray", shelfID: nil)
                        .id(ShelfScrollTarget.unclassified)
                    ForEach(model.state.shelves) { shelf in
                        shelfItem(name: shelf.name, icon: "books.vertical", shelfID: shelf.id)
                            .id(ShelfScrollTarget.shelf(shelf.id))
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
                    Button {
                        beginEditing(nil)
                    } label: {
                        Image(systemName: "plus").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).foregroundStyle(ReaderTheme.muted)
                    .help("新建书架").accessibilityLabel("新建书架").disabled(saving)
                    .id(ShelfScrollTarget.add)
                }.scrollTargetLayout()
            }
            .scrollPosition(id: $scrollTargetID, anchor: .leading)
            if editing {
                nameEditor
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(ReaderMotion.disclosure(reduceMotion), value: editing)
        .animation(ReaderMotion.disclosure(reduceMotion), value: selectedShelfID)
        .onChange(of: selectedShelfID, initial: true) { previousID, id in
            withAnimation(ReaderMotion.disclosure(reduceMotion || previousID == id)) {
                // Keep scroll position separate from selection so manual scrolling does not change the shelf.
                scrollTargetID = id.map(ShelfScrollTarget.shelf) ?? .unclassified
            }
        }
    }

    private func shelfItem(name: String, icon: String, shelfID: UUID?) -> some View {
        TopicShelfItem(
            name: name, icon: icon,
            count: model.state.papers.filter { model.state.shelfID(for: $0.id) == shelfID }.count,
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

private enum ShelfScrollTarget: Hashable {
    case unclassified
    case shelf(UUID)
    case add
}

private struct TopicShelfItem: View {
    let name: String
    let icon: String
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
                Image(systemName: icon).font(.system(size: 11))
                Text(name).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1).frame(maxWidth: 180)
                Text("\(count)").font(.system(size: 10)).foregroundStyle(ReaderTheme.muted)
            }
            .foregroundStyle(selected || targeted ? ReaderTheme.accent : ReaderTheme.muted)
            .padding(.horizontal, 12).frame(height: 44)
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
