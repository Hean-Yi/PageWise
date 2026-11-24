import CryptoKit
import Foundation

extension NoteAnchor {
    /// A new translation of the same passage has its own coordinate space.
    public static func pdfTranslationTarget(sentenceID: String, translation: String) -> String {
        let digest = SHA256.hash(data: Data(translation.utf8)).map { String(format: "%02x", $0) }.joined()
        return "pdf-translation:\(sentenceID):\(digest)"
    }

    public var readingPageIndex: Int? { pdfPageIndex ?? pdfTranslationPageIndex }

    public var pdfTranslationPageIndex: Int? {
        guard target.hasPrefix("pdf-translation:"), key.hasPrefix("original-"), let page = Int(key.dropFirst(9)),
            page >= 0, key == "original-\(page)"
        else { return nil }
        return page
    }
}

extension Highlight {
    /// An old translation stroke has no shared ID. A saved note can establish its scope by its
    /// exact translated passage, including the translation digest and sentence-local UTF-16 offset.
    public func legacyPDFTranslationNote(in notes: [ReadingNote], contentVersion version: String) -> ReadingNote? {
        guard strokeID == nil, contentVersion == version, let piece = pdfReadingAnchor,
            piece.pdfTranslationPageIndex != nil
        else { return nil }
        var match: ReadingNote?
        for note in notes
        where note.paperID == paperID && note.contentVersion == version && note.deletedAt == nil
            && !note.isDocumentSummary
        {
            guard note.anchors.allSatisfy({ $0.pdfTranslationPageIndex != nil }),
                note.anchors.contains(where: { anchor in
                    guard anchor.key == piece.key, anchor.target == piece.target,
                        anchor.start >= 0, anchor.start <= piece.start, piece.end <= anchor.end,
                        anchor.end - anchor.start == anchor.text.utf16.count
                    else { return false }
                    let range = NSRange(location: piece.start - anchor.start, length: piece.end - piece.start)
                    return (anchor.text as NSString).substring(with: range) == piece.text
                })
            else { continue }
            guard match == nil else { return nil }
            match = note
        }
        return match
    }

    public var pdfReadingAnchor: NoteAnchor? {
        guard pageKey == "original-\(pageIndex)", pageIndex >= 0, !text.isEmpty else { return nil }
        if let target = pdfTranslationTarget, let range = textRange, range.count == 2,
            range[0] >= 0, range[1] > range[0], range[1] - range[0] == text.utf16.count
        {
            return NoteAnchor(key: pageKey, target: target, text: text, start: range[0], end: range[1])
        }
        guard let start = pdfTextStart, start >= 0, start <= Int.max - text.utf16.count else { return nil }
        return NoteAnchor(key: pageKey, target: "pdf", text: text, start: start, end: start + text.utf16.count)
    }
}
