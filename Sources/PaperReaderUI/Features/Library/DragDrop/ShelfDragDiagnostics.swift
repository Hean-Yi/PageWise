import Foundation

/// Opt-in, content-free diagnostics for a local drag acceptance run.
enum ShelfDragDiagnostics {
    static func record(_ stage: String) {
        guard ProcessInfo.processInfo.environment["PAPERREADER_DEBUG_DRAG"] == "1" else { return }
        NSLog("PaperReader shelf-drag: %@", stage)
    }
}
