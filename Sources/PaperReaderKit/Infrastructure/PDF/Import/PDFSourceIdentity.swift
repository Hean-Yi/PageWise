import Foundation
import PDFKit

/// Only a versioned arXiv identifier printed in the first-page margin is a discovery hint.
/// Matching HTML still goes through content coverage and resource validation before publication.
enum PDFSourceIdentity {
    static func arxivCandidate(document: PDFDocument, title: String) -> PaperCandidate? {
        guard let page = document.page(at: 0),
            let regex = try? NSRegularExpression(
                pattern: #"arXiv:\s*(\d{4}\.\d{4,5}v[1-9]\d*)"#, options: .caseInsensitive)
        else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let lines = page.selection(for: NSRange(location: 0, length: page.numberOfCharacters))?.selectionsByLine() ?? []
        var identifiers = Set<String>()
        for line in lines {
            let rect = line.bounds(for: page)
            guard rect.maxX < bounds.minX + bounds.width * 0.15 || rect.minY > bounds.maxY - bounds.height * 0.12 else {
                continue
            }
            let text = line.string ?? ""
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                identifiers.insert((text as NSString).substring(with: match.range(at: 1)))
            }
        }
        guard identifiers.count == 1, let identifier = identifiers.first,
            let pdfURL = URL(string: "https://arxiv.org/pdf/" + identifier)
        else { return nil }
        return ArxivClient.verified(
            PaperCandidate(
                id: "https://arxiv.org/abs/" + identifier, title: String(title.prefix(500)), authors: "", year: "",
                pdfURL: pdfURL))
    }
}
