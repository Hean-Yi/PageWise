import PaperReaderKit
import SwiftUI

struct PaperDeletionRequest: Sendable {
    let title: String
    let confirm: @MainActor @Sendable () async -> Void

    init(title: String, confirm: @escaping @MainActor @Sendable () async -> Void) {
        self.title = title
        self.confirm = confirm
    }

    init(_ paper: Paper, model: ReaderModel) {
        let id = paper.id
        self.init(title: paper.displayTitle) { _ = await model.deletePaper(id) }
    }
}

extension EnvironmentValues {
    @Entry var requestPaperDeletion: (@MainActor @Sendable (PaperDeletionRequest) -> Void)?
}

struct DeletePaperButton: View {
    let paper: Paper
    let model: ReaderModel
    @Environment(\.requestPaperDeletion) private var requestPaperDeletion

    var body: some View {
        Button(role: .destructive) {
            requestPaperDeletion?(PaperDeletionRequest(paper, model: model))
        } label: {
            ReaderIcon(.delete, size: 17)
                .foregroundStyle(ReaderTheme.muted).readerIconTarget(macOS: 32)
        }
        .readerIconButtonStyle(.plain)
        .disabled(requestPaperDeletion == nil)
        .help("删除论文").accessibilityLabel("删除论文")
    }
}

extension View {
    func paperDeletionConfirmation() -> some View { modifier(PaperDeletionConfirmation()) }
}

private struct PaperDeletionConfirmation: ViewModifier {
    @Environment(\.requestPaperDeletion) private var parentRequest
    @State private var pending: PaperDeletionRequest?

    func body(content: Content) -> some View {
        if parentRequest != nil {
            content
        } else {
            content
                .environment(\.requestPaperDeletion) { request in
                    if pending == nil { pending = request }
                }
                .alert(
                    "永久删除这篇论文？",
                    isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                    presenting: pending
                ) { request in
                    Button("取消", role: .cancel) {}.keyboardShortcut(.defaultAction)
                    Button("永久删除", role: .destructive) { Task { await request.confirm() } }
                } message: { request in
                    Text("《\(request.title)》的书库副本、译文、批注、阅读笔记、对话和阅读记录都将删除。此操作无法撤销。")
                }
        }
    }
}
