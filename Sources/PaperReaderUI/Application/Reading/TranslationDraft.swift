import Foundation
import PaperReaderKit

public struct TranslationDraft: Sendable {
    public let paperID: UUID
    public let block: TextBlock
    public let text: String

    var html: String {
        var visible = text
        if let unfinished = visible.range(of: "[[MATH_", options: .backwards),
            !visible[unfinished.lowerBound...].contains("]]")
        {
            visible = String(visible[..<unfinished.lowerBound])
        }
        var translation = HTMLPaperParser.escape(visible).replacingOccurrences(of: "\n", with: "<br>")
        for (marker, math) in block.richContent?.mathematics ?? [:] {
            translation = translation.replacingOccurrences(of: marker, with: math)
        }
        var source = block.richContent?.html ?? "<p>\(HTMLPaperParser.escape(block.text))</p>"
        if block.richContent?.isFigure == true {
            source = HTMLPaperParser.escape(block.richContent?.translationInput ?? block.text)
            for (marker, math) in block.richContent?.mathematics ?? [:] {
                source = source.replacingOccurrences(of: marker, with: math)
            }
            source = "<p>\(source)</p>"
        }
        return
            "<div data-draft-key='\(block.id.uuidString)'>\(source)<div class='translation' lang='zh-Hans'>\(translation)<span aria-hidden='true'>▍</span></div></div>"
    }
}
