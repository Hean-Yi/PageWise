import SwiftUI
import UniformTypeIdentifiers

private struct ObsidianExportRequest {
    let paperID: UUID
    let includeDiscussion: Bool
}

extension EnvironmentValues {
    @Entry fileprivate var requestObsidianExport: (@MainActor (ObsidianExportRequest) -> Void)?
}

struct ObsidianExportButton: View {
    let model: ReaderModel
    let paperID: UUID
    var offersDiscussion = false
    @Environment(\.requestObsidianExport) private var request

    var body: some View {
        HStack(spacing: 6) {
            Button {
                request?(ObsidianExportRequest(paperID: paperID, includeDiscussion: false))
            } label: {
                if model.obsidianExportPaperID == paperID {
                    ProgressView().controlSize(.small).accessibilityLabel("正在整理到 Obsidian")
                } else {
                    Label("整理到 Obsidian", systemImage: "square.and.arrow.down")
                }
            }
            if offersDiscussion && model.hasObsidianDiscussion(paperID: paperID) {
                Menu {
                    Button("同时整理讨论…", systemImage: "text.bubble") {
                        request?(ObsidianExportRequest(paperID: paperID, includeDiscussion: true))
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.caption)
                }
                .menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("更多整理选项")
            }
        }
        .buttonStyle(.borderless).tint(ReaderTheme.accent)
        .disabled(model.busyAI || request == nil)
    }
}

extension View {
    func obsidianExportPresentation(model: ReaderModel) -> some View {
        modifier(ObsidianExportPresentation(model: model))
    }
}

private struct ObsidianExportPresentation: ViewModifier {
    let model: ReaderModel
    @State private var pending: ObsidianExportRequest?
    @State private var chooseFolder = false
    @State private var confirmDiscussion = false

    func body(content: Content) -> some View {
        content
            .environment(\.requestObsidianExport) { request in
                guard !model.busyAI, !chooseFolder, !confirmDiscussion else { return }
                pending = request
                if request.includeDiscussion {
                    confirmDiscussion = true
                } else {
                    Task { await save(request) }
                }
            }
            .confirmationDialog("将这篇论文的讨论交给 AI 一并整理？", isPresented: $confirmDiscussion, titleVisibility: .visible) {
                Button("包含讨论并整理") {
                    if let pending { Task { await save(pending) } }
                }
                Button("取消", role: .cancel) { pending = nil }
            }
            .fileImporter(isPresented: $chooseFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) {
                result in
                guard let request = pending else { return }
                switch result {
                case .success(let urls):
                    guard let url = urls.first else {
                        pending = nil
                        return
                    }
                    Task {
                        defer { pending = nil }
                        if await model.selectVault(url) {
                            await model.saveToObsidian(
                                paperID: request.paperID, includeDiscussion: request.includeDiscussion)
                        }
                    }
                case .failure(let error):
                    pending = nil
                    if (error as NSError).code != NSUserCancelledError { model.message = error.localizedDescription }
                }
            } onCancellation: {
                pending = nil
            }
    }

    private func save(_ request: ObsidianExportRequest) async {
        if await model.hasObsidianDirectory() {
            defer { pending = nil }
            await model.saveToObsidian(paperID: request.paperID, includeDiscussion: request.includeDiscussion)
        } else {
            chooseFolder = true
        }
    }
}
