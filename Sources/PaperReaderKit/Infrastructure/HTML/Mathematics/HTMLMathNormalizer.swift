import Foundation
import SwiftSoup

/// Converts explicitly delimited TeX before formula placeholders are assigned for translation.
enum HTMLMathNormalizer {
    static func normalize(_ root: Element) throws {
        var compiler: LatexMathCompiler?
        func compile(_ text: String, display: Bool) throws -> String {
            try Task.checkCancellation()
            if compiler == nil { compiler = try LatexMathCompiler() }
            return try compiler!.compile(text, display: display)
        }
        for script in try root.select("script[type^=math/tex]") {
            let markup = try compile(script.data(), display: try script.attr("type").contains("mode=display"))
            try script.before(markup)
            try script.remove()
        }
        for element in try root.select("[data-latex]") {
            guard try element.select("math").isEmpty() else { continue }
            let markup = try compile(element.attr("data-latex"), display: element.tagName() == "div")
            try element.html(markup)
            try element.removeAttr("data-latex")
        }
        let pattern = #"(?<!\\)(?:\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]|\\\(([\s\S]+?)\\\)|\$([^$\n]+?)\$(?![0-9]))"#
        let regex = try NSRegularExpression(pattern: pattern)
        func visit(_ node: Node) throws {
            if let element = node as? Element,
                ["math", "pre", "code", "script", "style", "svg", "textarea"].contains(element.tagName())
            {
                return
            }
            if let text = node as? TextNode {
                let value = text.getWholeText()
                let ns = value as NSString
                let matches = regex.matches(in: value, range: NSRange(location: 0, length: ns.length))
                guard !matches.isEmpty else { return }
                var html = ""
                var offset = 0
                for match in matches {
                    html += HTMLPaperParser.escape(
                        ns.substring(with: NSRange(location: offset, length: match.range.location - offset)))
                    let group = (1...4).first { match.range(at: $0).location != NSNotFound }!
                    html += try compile(ns.substring(with: match.range(at: group)), display: group <= 2)
                    offset = NSMaxRange(match.range)
                }
                html += HTMLPaperParser.escape(ns.substring(from: offset))
                try text.before(html)
                try text.remove()
            } else {
                for child in node.getChildNodes() { try visit(child) }
            }
        }
        try visit(root)
    }
}
