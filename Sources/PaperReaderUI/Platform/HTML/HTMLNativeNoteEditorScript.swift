import Foundation

/// Local, bundled source-preserving Markdown editor. No CDN or paper-provided scripts.
enum HTMLNativeNoteEditorScript {
    static let source: String = {
        guard let url = Bundle.module.url(forResource: "editor", withExtension: "js", subdirectory: "NoteEditor.bundle")
        else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()
}
