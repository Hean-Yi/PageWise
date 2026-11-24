import SwiftUI
import UniformTypeIdentifiers

struct PublisherPDFImportLabel: View {
    var body: some View {
        Label("导入已下载的 PDF", systemImage: "doc.badge.plus")
    }
}

struct PublisherPDFImportButton: View {
    let importFile: (URL) -> Void
    let onFailure: (Error) -> Void
    @State private var choosingPDF = false

    var body: some View {
        Button {
            choosingPDF = true
        } label: {
            PublisherPDFImportLabel()
        }
        .buttonStyle(.bordered)
        .publisherPDFImporter(isPresented: $choosingPDF, importFile: importFile, onFailure: onFailure)
    }
}

extension View {
    func publisherPDFImporter(
        isPresented: Binding<Bool>, importFile: @escaping (URL) -> Void, onFailure: @escaping (Error) -> Void,
        onCancellation: @escaping () -> Void = {}
    ) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { importFile(url) } else { onCancellation() }
            case .failure(let error):
                if (error as? CocoaError)?.code == .userCancelled { onCancellation() } else { onFailure(error) }
            }
        } onCancellation: {
            onCancellation()
        }
    }
}
