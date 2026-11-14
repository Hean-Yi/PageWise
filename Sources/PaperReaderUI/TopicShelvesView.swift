import PaperReaderKit
import SwiftUI
import UniformTypeIdentifiers

/// Uses a dedicated type so internal moves never compete with Finder PDF URLs.
enum PaperShelfDrag {
    static let typeIdentifier = "dev.paperreader.paper-reference"

    static func provider(_ paperID: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(paperID.uuidString.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    static func paperID(from data: Data) -> UUID? {
        guard data.count == 36, let value = String(data: data, encoding: .utf8) else { return nil }
        return UUID(uuidString: value)
    }

    @MainActor static func receive(
        _ providers: [NSItemProvider], model: ReaderModel, shelfID: UUID?
    ) -> Bool {
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(typeIdentifier) }
        guard !matching.isEmpty else { return false }
        ShelfDragDiagnostics.record("target-receive")
        for provider in matching {
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                guard let data, let id = paperID(from: data) else {
                    ShelfDragDiagnostics.record("target-invalid-data")
                    return
                }
                Task { @MainActor in
                    guard model.state.papers.contains(where: { $0.id == id }) else { return }
                    let saved = await model.movePaper(id, to: shelfID)
                    ShelfDragDiagnostics.record(saved ? "target-saved" : "target-save-failed")
                }
            }
        }
        return true
    }
}

struct TopicShelvesView: View {
    @Bindable var model: ReaderModel
    @Binding var selectedShelfID: UUID?
    @State private var editing = false
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var saving = false
    @State private var unclassifiedTargeted = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("主题书架").font(.system(size: 12, weight: .medium)).foregroundStyle(ReaderTheme.muted)
                Spacer()
                Button {
                    editingID = nil
                    name = ""
                    editing = true
                    nameFocused = true
                } label: {
                    Label("新建书架", systemImage: "plus")
                }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(ReaderTheme.accent)
            }
            if editing {
                HStack {
                    TextField(editingID == nil ? "书架名称" : "新的书架名称", text: $name)
                        .textFieldStyle(.roundedBorder).focused($nameFocused).onSubmit { saveName() }
                    Button("保存", action: saveName).disabled(
                        saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("取消") { editing = false }.disabled(saving)
                }.font(.system(size: 12))
            }
            if !model.state.shelves.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 18) {
                        ForEach(model.state.shelves) { shelf in
                            TopicShelfCard(
                                shelf: shelf,
                                papers: LibraryQuery.papers(in: model.state).filter {
                                    model.state.shelfID(for: $0.id) == shelf.id
                                },
                                selected: selectedShelfID == shelf.id,
                                select: { selectedShelfID = shelf.id },
                                accepts: { id in model.state.papers.contains { $0.id == id } },
                                move: { PaperShelfDrag.receive($0, model: model, shelfID: shelf.id) }
                            )
                            .contextMenu {
                                Button("打开书架") { selectedShelfID = shelf.id }
                                Button("改名") {
                                    editingID = shelf.id
                                    name = shelf.name
                                    editing = true
                                    nameFocused = true
                                }
                                Button("删除书架", role: .destructive) {
                                    Task {
                                        if await model.deleteShelf(shelf.id), selectedShelfID == shelf.id {
                                            selectedShelfID = nil
                                        }
                                    }
                                }
                            }
                        }
                    }.padding(.vertical, 6)
                }.scrollIndicators(.hidden)
            }
            HStack(spacing: 9) {
                Image(systemName: "tray")
                Text("未分类")
                Text("\(model.state.papers.filter { model.state.shelfID(for: $0.id) == nil }.count)")
                Spacer()
                if selectedShelfID != nil {
                    Button("返回全部论文") { selectedShelfID = nil }.buttonStyle(.plain).foregroundStyle(ReaderTheme.accent)
                } else {
                    Text("拖入此处移出书架").font(.system(size: 10)).foregroundStyle(ReaderTheme.muted)
                }
            }
            .font(.system(size: 12)).padding(12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .background(
                unclassifiedTargeted ? ReaderTheme.accent.opacity(0.16) : ReaderTheme.ink.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 8)
            )
            #if os(macOS)
                .overlay {
                    NativeShelfDrop(
                        activate: { selectedShelfID = nil },
                        accepts: { id in model.state.papers.contains { $0.id == id } },
                        receive: { id in
                            PaperShelfDrag.receive([PaperShelfDrag.provider(id)], model: model, shelfID: nil)
                        },
                        highlight: { unclassifiedTargeted = $0 })
                }
            #else
                .onDrop(of: [PaperShelfDrag.typeIdentifier], isTargeted: $unclassifiedTargeted) { providers in
                    PaperShelfDrag.receive(providers, model: model, shelfID: nil)
                }
            #endif
        }
    }

    private func saveName() {
        guard !saving else { return }
        saving = true
        Task {
            let saved: Bool
            if let editingID {
                saved = await model.renameShelf(editingID, name: name)
            } else {
                saved = await model.createShelf(name: name) != nil
            }
            saving = false
            if saved { editing = false }
        }
    }

}

private struct TopicShelfCard: View {
    let shelf: Shelf
    let papers: [Paper]
    let selected: Bool
    let select: () -> Void
    let accepts: (UUID) -> Bool
    let move: ([NSItemProvider]) -> Bool
    @State private var targeted = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    if papers.isEmpty {
                        Image(systemName: "books.vertical").font(.system(size: 34, weight: .ultraLight))
                            .foregroundStyle(ReaderTheme.muted)
                    } else {
                        ForEach(Array(papers.prefix(3).enumerated().reversed()), id: \.element.id) { index, paper in
                            BookCoverView(paper: paper).frame(width: 64)
                                .rotationEffect(.degrees(Double(index) * 7 - 5))
                                .offset(x: CGFloat(index) * 17 - 12, y: CGFloat(index) * -3)
                                .shadow(color: .black.opacity(0.1), radius: 3, y: 3)
                        }
                    }
                }.frame(maxWidth: .infinity).frame(height: 104)
                HStack(alignment: .firstTextBaseline) {
                    Text(shelf.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(papers.count)").font(.system(size: 11)).foregroundStyle(ReaderTheme.muted)
                }
            }.padding(14).frame(width: 174)
                .background(ReaderTheme.elevated.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10).strokeBorder(
                        targeted || selected ? ReaderTheme.accent : ReaderTheme.line, lineWidth: targeted ? 2 : 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityLabel("\(shelf.name)，\(papers.count) 篇论文")
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
            .onChange(of: targeted) { _, value in
                ShelfDragDiagnostics.record(value ? "target-enter" : "target-exit")
            }
    }
}
