import PaperReaderUI
import SwiftUI

@main
struct PaperReaderApp: App {
    @State private var model: ReaderModel?
    private let startupError: String?

    init() {
        do {
            let root = ProcessInfo.processInfo.environment["PAPERREADER_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            _model = State(initialValue: try ReaderModel(root: root))
            startupError = nil
        } catch {
            _model = State(initialValue: nil)
            startupError = error.localizedDescription
        }
    }
    var body: some Scene {
        #if os(macOS)
            Window("PageWise", id: "main") {
                content.frame(minWidth: 1000, minHeight: 640)
            }.defaultSize(width: 1320, height: 860)
                .commands { ReaderSettingsCommands() }
        #else
            WindowGroup { content }
        #endif
    }
    @ViewBuilder var content: some View {
        if let model {
            LibraryView(model: model)
        } else {
            ContentUnavailableView(
                "无法打开书库", systemImage: "externaldrive.badge.exclamationmark",
                description: Text(startupError ?? "未知错误，原文件已保留。"))
        }
    }
}
