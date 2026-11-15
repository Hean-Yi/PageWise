import Foundation
import SwiftSoup

/// Parses only arXiv article content. No source markup is executed or passed through unchecked.
public actor HTMLPaperParser {
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = NetworkTransport()) { self.transport = transport }

    public func parse(_ data: Data, at source: URL) async throws -> [TextBlock] {
        guard data.count <= 8_000_000, let html = String(data: data, encoding: .utf8)
        else { throw ReaderError.message("HTML 正文结构无法确认，使用 PDF 解析。") }
        let document = try SwiftSoup.parse(html)
        document.outputSettings().syntax(syntax: .xml).escapeMode(.xhtml).prettyPrint(pretty: false)
        for meta in try document.select("meta[name=citation_arxiv_id]") {
            let identifier = try meta.attr("content")
            guard identifier == String(source.path.dropFirst(6)) else {
                throw ReaderError.message("HTML 与所选论文版本不一致，使用 PDF。")
            }
        }
        guard let article = try document.select("article.ltx_document").first() else {
            throw ReaderError.message("HTML 正文结构无法确认，使用 PDF 解析。")
        }
        // LaTeXML can report an unknown floating-layout wrapper while preserving the
        // complete algorithm listing. Accept only that verifiable layout-only case.
        for error in try article.select(".ltx_ERROR") {
            guard try error.text() == "{wrapfloat}", let parent = error.parent(),
                parent.hasClass("ltx_para"), try !parent.select(".ltx_listing").isEmpty(),
                let caption = try parent.select("p").first(),
                let prefix = caption.getChildNodes().first as? TextNode,
                prefix.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines)
                    .range(of: #"^algorithm[RLrl][0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil
            else { throw ReaderError.message("HTML 有未转换的内容，使用 PDF 保留完整原文。") }
            try prefix.remove()
            try error.remove()
        }
        guard try article.select("canvas,iframe,video,audio,form").isEmpty()
        else {
            throw ReaderError.message("HTML 包含尚不支持的内容，使用 PDF 保留完整原文。")
        }
        try HTMLMathNormalizer.normalize(article)
        try await HTMLImageNormalizer.normalize(article, source: source, transport: transport)
        try article.select("script,style,noscript,.ltx_page_header,.ltx_page_footer").remove()
        try HTMLFrontMatterNormalizer.normalize(article)
        var elements: [Element] = []
        func collect(_ node: Element) throws {
            if node.tagName() == "figure", try node.select("figure").contains(where: { $0 !== node }) {
                for child in node.children() { try collect(child) }
                return
            }
            let tags: Set<String> = [
                "p", "h1", "h2", "h3", "h4", "h5", "h6", "figure", "figcaption", "table", "pre", "ul", "ol", "math",
                "blockquote",
            ]
            if tags.contains(node.tagName()) || node.hasAttr("data-pr-image") || node.hasClass("ltx_equation")
                || node.hasClass("ltx_equationgroup")
                || node.hasClass("ltx_listing")
                || node.hasClass("ltx_authors")
            {
                elements.append(node)
            } else {
                for child in node.getChildNodes() {
                    if let element = child as? Element {
                        try collect(element)
                    } else if let text = child as? TextNode,
                        !text.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        let wrapper = try Element(Tag.valueOf("p"), "")
                        try wrapper.text(text.getWholeText())
                        elements.append(wrapper)
                    }
                }
            }
        }
        try collect(article)
        guard !elements.isEmpty, elements.count <= 5_000 else { throw ReaderError.message("HTML 正文为空或过大。") }
        var emittedAnchors = Set<String>()
        return try elements.map { element in
            var mathematics: [String: String] = [:]
            var descriptions: [String: String] = [:]
            let converted = try Self.convert(element, mathematics: &mathematics, descriptions: &descriptions)
            let aliases = element.parents().reversed().compactMap { Self.referenceID((try? $0.attr("id")) ?? "") }
                .filter { emittedAnchors.insert($0).inserted }
                .map { "<span id=\"\($0)\"></span>" }.joined()
            var block = TextBlock(sourcePage: -1, text: converted.text.trimmingCharacters(in: .whitespacesAndNewlines))
            let containsTable = try !element.select("table").isEmpty()
            block.richContent = RichContent(
                html: aliases + converted.html,
                translationInput: element.hasClass("ltx_listing") || element.hasClass("ltx_authors")
                    || element.hasClass("ltx_biblist") || element.hasClass("ltx_equation")
                    || element.hasClass("ltx_equationgroup") || element.tagName() == "math"
                    || element.tagName() == "pre" || element.tagName() == "code"
                    || element.tagName() == "table" || element.hasClass("ltx_table")
                    || containsTable
                    ? "" : converted.input.trimmingCharacters(in: .whitespacesAndNewlines),
                mathematics: mathematics, mathDescriptions: descriptions)
            let captions = try element.select("figcaption")
            if captions.count == 1, let caption = captions.first() {
                var captionMath: [String: String] = [:]
                var captionDescriptions: [String: String] = [:]
                let part = try Self.convert(caption, mathematics: &captionMath, descriptions: &captionDescriptions)
                block.richContent?.figureCaption = FigureCaption(
                    text: part.text.trimmingCharacters(in: .whitespacesAndNewlines), html: part.html,
                    translationInput: part.input.trimmingCharacters(in: .whitespacesAndNewlines),
                    mathematics: captionMath, mathDescriptions: captionDescriptions)
            }
            let images = try element.select("img")
            block.richContent?.imageSizes = try images.map {
                PaperImageSize(width: Double(try $0.attr("width")) ?? 0, height: Double(try $0.attr("height")) ?? 0)
            }
            block.richContent?.isFigure = !images.isEmpty() || element.hasAttr("data-pr-image")
            block.richContent?.imageTextForCoverage = try element.select("[data-pr-coverage]").map {
                try $0.attr("data-pr-coverage")
            }.joined(separator: " ")
            block.imageWarnings = try element.select("[data-pr-notice]").map { try $0.text() }
            block.hasImageFailure = try !element.select("[data-pr-failure]").isEmpty()
            return block
        }
    }

    private struct Fragment {
        var html: String
        var text: String
        var input: String
    }
    private static let tags: Set<String> = [
        "p", "div", "span", "h1", "h2", "h3", "h4", "h5", "h6", "figure", "figcaption", "table", "thead", "tbody",
        "tfoot", "tr", "td", "th",
        "pre", "code", "ul", "ol", "li", "blockquote", "em", "strong", "b", "i", "sub", "sup", "br", "img",
        "math", "mi", "mn", "mo", "mtext", "mrow", "msup", "msub", "msubsup", "mfrac", "msqrt", "mroot", "mfenced",
        "mover", "munder", "munderover",
        "mtable", "mtr", "mtd", "mspace", "menclose", "mstyle", "mpadded", "mphantom", "mmultiscripts", "mprescripts",
        "none", "semantics",
        "details", "summary",
        "a",
    ]

    private static func convert(
        _ node: Node, mathematics: inout [String: String], descriptions: inout [String: String], inMath: Bool = false
    ) throws -> Fragment {
        if let text = node as? TextNode {
            let value = text.getWholeText()
            return Fragment(html: escape(value), text: value, input: value)
        }
        guard let element = node as? Element else { return Fragment(html: "", text: "", input: "") }
        let tag = element.tagName()
        if element.hasAttr("data-pr-notice") {
            return Fragment(
                html: "<div class='image-notice'>" + escape(try element.text()) + "</div>", text: "", input: "")
        }
        if ["annotation", "annotation-xml", "script", "style"].contains(tag) {
            return Fragment(html: "", text: "", input: "")
        }
        if inMath && !tags.contains(tag) { throw ReaderError.message("HTML 公式包含不支持的结构，使用 PDF。") }
        var children = Fragment(html: "", text: "", input: "")
        for child in element.getChildNodes() {
            let part = try convert(
                child, mathematics: &mathematics, descriptions: &descriptions, inMath: inMath || tag == "math")
            children.html += part.html
            children.text += part.text
            children.input += part.input
        }
        guard tags.contains(tag) else { return children }
        var attributes = ""
        if let anchor = Self.referenceID(try element.attr("id")) { attributes += " id=\"\(anchor)\"" }
        if tag == "a" {
            let href = try element.attr("href")
            if href.hasPrefix("#"),
                let anchor = Self.referenceID(String(href.dropFirst()).removingPercentEncoding ?? "")
            {
                attributes += " href=\"#\(anchor)\""
            } else if let url = URL(string: href), ["https", "http"].contains(url.scheme ?? ""),
                url.host != nil, url.user == nil, url.password == nil
            {
                attributes += " href=\"\(Self.escape(url.absoluteString))\" rel=\"noreferrer\""
            }
        }
        if element.hasClass("ltx_authors") { attributes += " class=\"paper-authors\"" }
        if element.hasClass("ltx_equation") || element.hasClass("ltx_equationgroup") {
            attributes += " class=\"paper-equation\""
        }
        let names =
            tag == "img"
            ? ["src", "alt", "width", "height"]
            : (tag == "td" || tag == "th"
                ? ["colspan", "rowspan"]
                : (inMath || tag == "math"
                    ? [
                        "display", "mathvariant", "stretchy", "fence", "separator", "accent", "accentunder",
                        "columnalign", "rowalign", "linethickness", "columnspan", "rowspan", "columnspacing",
                        "rowspacing", "columnlines", "rowlines", "displaystyle", "scriptlevel", "notation", "lspace",
                        "rspace", "width", "height", "depth",
                    ] : []))
        for name in names {
            let value = try element.attr(name)
            if !value.isEmpty { attributes += " \(name)=\"\(escape(value))\"" }
        }
        let markup = "<\(tag)\(attributes)>" + (["br", "img"].contains(tag) ? "" : children.html + "</\(tag)>")
        if tag == "math" && !inMath {
            let marker = "[[MATH_\(mathematics.count + 1)]]"
            let alt = try element.attr("alttext")
            let description = alt.isEmpty ? children.text : alt
            mathematics[marker] = markup
            descriptions[marker] = description
            return Fragment(html: markup, text: description, input: marker)
        }
        let separator =
            ["td", "th"].contains(tag)
            ? "\t" : ["p", "div", "li", "tr", "h1", "h2", "h3", "figcaption", "br"].contains(tag) ? "\n" : ""
        return Fragment(html: markup, text: children.text + separator, input: children.input + separator)
    }

    public static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func referenceID(_ value: String) -> String? {
        guard value.range(of: #"^[A-Za-z][A-Za-z0-9_.:-]{0,180}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return "ref-" + value
    }
}
