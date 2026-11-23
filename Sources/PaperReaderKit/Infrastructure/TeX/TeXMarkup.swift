import CryptoKit
import Foundation
import SwiftSoup

/// Converts a deliberately bounded LaTeX subset into application-owned semantic markup.
/// Unknown body commands fail the entire source before a single reading block is published.
final class TeXMarkup {
    let compiler: LatexMathCompiler
    var labels: Set<String> = []
    var references: Set<String> = []
    private var byline = TeXByline()
    private var bibliographyLabels: [String: String] = [:]
    var title = ""
    var titleEmitted = false
    var depth = 0
    init() throws { compiler = try LatexMathCompiler() }

    func document(_ source: String) throws -> String {
        guard
            source.range(
                of:
                    #"\\(?:AtBeginDocument|AtEndDocument|includeonly|let|catcode|csname|if(?!f\b)[A-Za-z]*|else|fi|endinput)\b"#,
                options: .regularExpression) == nil,
            let begin = source.range(of: "\\begin{document}"),
            let end = source.range(of: "\\end{document}", range: begin.upperBound..<source.endIndex)
        else { throw TeXArchive.failure("不支持的动态结构或文档环境") }
        let preamble = String(source[..<begin.lowerBound])
        var cursor = TeXCursor(preamble)
        while !cursor.ended {
            if cursor.peek == "\\" {
                let command = cursor.command()
                if command == "title" {
                    _ = try cursor.optional()
                    title = try cursor.group()
                } else if ["author", "affil", "affiliation", "institute"].contains(command) {
                    let mark = try cursor.optional()
                    byline.append(try cursor.group(), mark: mark, author: command == "author")
                }
            } else {
                cursor.index += 1
            }
        }
        let body = try render(String(source[begin.upperBound..<end.lowerBound]))
        guard references.isSubset(of: labels) else { throw TeXArchive.failure("存在无法定位的引用目标") }
        let html = "<article class='ltx_document'>" + body + "</article>"
        guard !bibliographyLabels.isEmpty, html.contains("data-tex-cite") else { return html }
        let document = try SwiftSoup.parseBodyFragment(html)
        document.outputSettings().syntax(syntax: .xml).escapeMode(.xhtml).prettyPrint(pretty: false)
        for link in try document.select("a[data-tex-cite]") {
            if let label = bibliographyLabels[try link.attr("href")] {
                try link.text(Self.citationLabel(label, command: link.attr("data-tex-cite")))
            }
            try link.removeAttr("data-tex-cite")
        }
        return try document.body()?.html() ?? html
    }

    func render(_ text: String, inline: Bool = false) throws -> String {
        depth += 1
        defer { depth -= 1 }
        guard depth <= 40 else { throw TeXArchive.failure("正文嵌套层级过深") }
        var cursor = TeXCursor(text)
        var result = ""
        var paragraph = ""
        func flush() {
            if !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result += inline ? paragraph : "<p>" + paragraph + "</p>"
            }
            paragraph = ""
        }
        while !cursor.ended {
            try Task.checkCancellation()
            let c = cursor.peek!
            if c == "$" {
                cursor.index += 1
                let display = cursor.peek == "$"
                if display { cursor.index += 1 }
                let math = try cursor.until(display ? "$$" : "$")
                let markup = try compiler.compile(math, display: display)
                if display && !inline {
                    flush()
                    result += "<div class='ltx_equation'>" + markup + "</div>"
                } else {
                    paragraph += markup
                }
            } else if c == "{" {
                paragraph += try render(cursor.group(), inline: true)
            } else if c == "}" || c == "&" || c == "#" || c == "^" || c == "_" {
                throw TeXArchive.failure("正文出现无法解释的特殊字符")
            } else if c == "\\" {
                let command = cursor.command()
                switch command {
                case "(", "[":
                    let display = command == "["
                    let math = try cursor.until(display ? "\\]" : "\\)")
                    let markup = try compiler.compile(math, display: display)
                    if display && !inline {
                        flush()
                        result += "<div class='ltx_equation'>" + markup + "</div>"
                    } else {
                        paragraph += markup
                    }
                case "author", "affil", "affiliation", "institute":
                    guard !inline, !titleEmitted else { throw TeXArchive.failure("署名位于不支持的位置") }
                    let mark = try cursor.optional()
                    byline.append(try cursor.group(), mark: mark, author: command == "author")
                case "maketitle":
                    guard !inline, !titleEmitted else { throw TeXArchive.failure("重复或嵌套标题") }
                    titleEmitted = true
                    flush()
                    if !title.isEmpty { result += "<h1>" + (try render(title, inline: true)) + "</h1>" }
                    result += byline.html
                case "section", "subsection", "subsubsection", "paragraph", "subparagraph":
                    guard !inline else { throw TeXArchive.failure("嵌套章节") }
                    flush()
                    if cursor.peek == "*" { cursor.index += 1 }
                    _ = try cursor.optional()
                    let level = ["section": 2, "subsection": 3, "subsubsection": 4, "paragraph": 5, "subparagraph": 6][
                        command]!
                    result += "<h\(level)>" + (try render(cursor.group(), inline: true)) + "</h\(level)>"
                case "begin":
                    let environment = try cursor.group()
                    _ = try cursor.optional()
                    let content = try environmentBody(environment, cursor: &cursor)
                    let markup = try environmentMarkup(environment, content: content)
                    if inline {
                        paragraph += markup
                    } else {
                        flush()
                        result += markup
                    }
                case "textbf", "textit", "emph", "texttt", "textrm", "textsf", "textnormal", "mbox", "underline":
                    let tags = ["textbf": "strong", "textit": "em", "emph": "em", "texttt": "code", "underline": "u"]
                    let tag = tags[command] ?? "span"
                    paragraph += "<\(tag)>" + (try render(cursor.group(), inline: true)) + "</\(tag)>"
                case "label":
                    let label = try cursor.group()
                    guard labels.insert(label).inserted else { throw TeXArchive.failure("重复引用标签") }
                    paragraph += "<span id='\(anchor(label))'></span>"
                case "ref", "eqref", "autoref", "pageref":
                    guard command != "pageref" else { throw TeXArchive.failure("源码页码引用需要原 PDF") }
                    let label = try cursor.group()
                    references.insert(label)
                    paragraph += "<a href='#\(anchor(label))'>" + escape(label) + "</a>"
                case "cite", "citep", "citet", "citealp", "citeauthor", "citeyear":
                    if cursor.peek == "*" { cursor.index += 1 }
                    let prefix = try cursor.optional()
                    let suffix = try cursor.optional()
                    let keys = try cursor.group().split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    let brackets = ["cite", "citep"].contains(command)
                    if brackets { paragraph += "[" }
                    if let prefix, suffix != nil { paragraph += try render(prefix, inline: true) + " " }
                    paragraph += keys.map { key in
                        references.insert("bib:" + key)
                        return "<a data-tex-cite='\(command)' href='#\(anchor("bib:" + key))'>\(escape(key))</a>"
                    }.joined(separator: ", ")
                    if let note = suffix ?? prefix { paragraph += ", " + (try render(note, inline: true)) }
                    if brackets { paragraph += "]" }
                case "includegraphics":
                    let path = try cursor.group()
                    let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
                    paragraph += "<img src='\(escape("https://arxiv.org/html/tex-local/" + encoded))' alt='论文原图'>"
                case "caption":
                    _ = try cursor.optional()
                    flush()
                    result += "<figcaption>" + (try render(cursor.group(), inline: true)) + "</figcaption>"
                case "footnote":
                    _ = try cursor.optional()
                    paragraph += " (" + (try render(cursor.group(), inline: true)) + ")"
                case "href":
                    let url = try cursor.group()
                    let label = try render(cursor.group(), inline: true)
                    guard let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme),
                        parsed.host != nil, parsed.user == nil, parsed.password == nil
                    else { throw TeXArchive.failure("不支持的链接") }
                    paragraph += "<a href='\(escape(url))'>\(label)</a>"
                case "url", "path":
                    paragraph += escape(try cursor.group())
                case "item":
                    flush()
                    let label = try cursor.optional()
                    paragraph += "• " + (label.map { escape($0) + " " } ?? "")
                case "par", "smallskip", "medskip", "bigskip": flush()
                case "newblock": paragraph += " "
                case "-": break
                case "\\":
                    _ = try cursor.optional()
                    paragraph += "<br>"
                case "textcolor":
                    _ = try cursor.group()
                    paragraph += try render(cursor.group(), inline: true)
                case "bibliographystyle", "vspace", "hspace":
                    if cursor.peek == "*" { cursor.index += 1 }
                    _ = try cursor.group()
                case "centering", "raggedright", "noindent", "indent", "protect", "relax", "leavevmode",
                    "small", "footnotesize", "scriptsize", "tiny", "normalsize", "large", "Large", "LARGE",
                    "huge", "Huge", "bfseries", "itshape", "rmfamily", "sffamily", "ttfamily", "slshape",
                    "appendix", "clearpage", "newpage", "pagebreak", "nopagebreak":
                    break
                case "%", "&", "#", "_", "$", "{", "}": paragraph += escape(command)
                case " ", ",", ";", ":", "quad", "qquad", "enspace", "thinspace": paragraph += " "
                case "!": break
                case "LaTeX": paragraph += "LaTeX"
                case "TeX": paragraph += "TeX"
                case "ldots", "dots", "textellipsis": paragraph += "…"
                case "textendash": paragraph += "–"
                case "textemdash": paragraph += "—"
                case "textasciitilde": paragraph += "~"
                case "textbackslash": paragraph += "\\"
                case "textless": paragraph += "&lt;"
                case "textgreater": paragraph += "&gt;"
                default: throw TeXArchive.failure("存在尚不支持的正文命令 \\" + command)
                }
            } else if c == "\n" {
                cursor.index += 1
                var newlines = 1
                while let next = cursor.peek, next.isWhitespace {
                    if next == "\n" { newlines += 1 }
                    cursor.index += 1
                }
                if newlines >= 2 && !inline { flush() } else { paragraph += " " }
            } else {
                paragraph += c == "~" ? " " : escape(String(c))
                cursor.index += 1
            }
        }
        flush()
        return result
    }

    private func environmentBody(_ name: String, cursor: inout TeXCursor) throws -> String {
        let start = cursor.index
        var nesting = 1
        while !cursor.ended {
            let before = cursor.index
            if cursor.peek == "\\" {
                let command = cursor.command()
                if command == "begin" || command == "end" {
                    let environment = try cursor.group()
                    if environment == name {
                        nesting += command == "begin" ? 1 : -1
                        if nesting == 0 { return String(cursor.characters[start..<before]) }
                    }
                }
            } else {
                cursor.index += 1
            }
        }
        throw TeXArchive.failure("环境未闭合")
    }

    private func environmentMarkup(_ name: String, content: String) throws -> String {
        switch name {
        case "abstract": return "<h2>Abstract</h2>" + (try render(content))
        case "figure", "figure*": return "<figure>" + (try render(content)) + "</figure>"
        case "table", "table*": return "<figure class='ltx_table'>" + (try render(content)) + "</figure>"
        case "center", "flushleft", "flushright", "quote", "quotation", "itemize", "enumerate", "description":
            return try render(content)
        case "theorem", "lemma", "proposition", "corollary", "definition", "proof", "remark", "example":
            return "<p><strong>\(name.capitalized).</strong></p>" + (try render(content))
        case "equation", "equation*", "align", "align*", "gather", "gather*", "multline", "multline*", "displaymath":
            var cursor = TeXCursor(content)
            var math = ""
            var anchors = ""
            while !cursor.ended {
                let start = cursor.index
                if cursor.peek == "\\" {
                    let command = cursor.command()
                    if command == "label" {
                        let label = try cursor.group()
                        guard labels.insert(label).inserted else { throw TeXArchive.failure("重复公式标签") }
                        anchors += "<span id='\(anchor(label))'></span>"
                        continue
                    }
                    if command == "nonumber" || command == "notag" { continue }
                } else {
                    cursor.index += 1
                }
                math += String(cursor.characters[start..<cursor.index])
            }
            if name.hasPrefix("align") { math = "\\begin{aligned}" + math + "\\end{aligned}" }
            if name.hasPrefix("gather") || name.hasPrefix("multline") {
                math = "\\begin{gathered}" + math + "\\end{gathered}"
            }
            return "<div class='ltx_equation'>" + anchors + (try compiler.compile(math, display: true)) + "</div>"
        case "thebibliography":
            return try bibliography(content)
        case "verbatim", "lstlisting": return "<pre>" + escape(content) + "</pre>"
        case "tabular", "tabular*": return try table(content, starred: name == "tabular*")
        default: throw TeXArchive.failure("存在尚不支持的环境 " + name)
        }
    }

    /// Natbib's optional label commonly contains a short author list, a parenthesized year and a long list.
    private static func citationLabel(_ label: String, command: String) throws -> String {
        if let match = label.firstMatch(of: /^(.+?)\s*\(\s*((?:1[5-9]|20)[0-9]{2}[a-z]?)\s*\)/) {
            let authors = match.1.trimmingCharacters(in: .whitespaces)
            let year = String(match.2)
            switch command {
            case "citeauthor": return authors
            case "citeyear": return year
            case "citet": return "\(authors) (\(year))"
            default: return "\(authors), \(year)"
            }
        }
        if ["citeauthor", "citeyear", "citet"].contains(command) {
            // A numeric label alone has no source-grounded author name or date.
            throw TeXArchive.failure("作者年份引用缺少可核对的标签")
        }
        return label
    }

    private func bibliography(_ content: String) throws -> String {
        var cursor = TeXCursor(content)
        _ = try cursor.group()  // The standard environment starts with its widest printed label.
        var result = "<ol class='ltx_biblist tex-bibliography'>"
        var start = cursor.index
        var labelHTML: String?
        var index = 0
        func finish(at end: Int) throws {
            let source = String(cursor.characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let labelHTML {
                result += "<li>" + labelHTML + " " + (try render(source, inline: true)) + "</li>"
            } else if !source.isEmpty {
                // Bibliography packages can emit setup commands before the first item.
                // Preserve supported material and let the normal parser reject unknown commands.
                result += try render(source)
            }
        }
        while !cursor.ended {
            let pos = cursor.index
            if cursor.peek == "{" {
                _ = try cursor.group()
                continue
            }
            guard cursor.peek == "\\" else {
                cursor.index += 1
                continue
            }
            if try cursor.literalEnvironment() != nil { continue }
            guard cursor.command() == "bibitem" else { continue }
            try finish(at: pos)
            let optionalLabel = try cursor.optional()
            let key = try cursor.group()
            guard labels.insert("bib:" + key).inserted else { throw TeXArchive.failure("重复参考文献") }
            index += 1
            let id = anchor("bib:" + key)
            let label: String
            if let optionalLabel {
                label = try SwiftSoup.parseBodyFragment(render(optionalLabel, inline: true)).text()
            } else {
                label = String(index)
            }
            bibliographyLabels["#" + id] = label
            let display = try Self.citationLabel(label, command: "cite")
            labelHTML = "<span id='\(id)'>[\(escape(display))]</span>"
            start = cursor.index
        }
        try finish(at: cursor.index)
        return result + "</ol>"
    }

    private func table(_ content: String, starred: Bool) throws -> String {
        var cursor = TeXCursor(content)
        if starred { _ = try cursor.group() }
        _ = try cursor.optional()
        let columns = try cursor.group()
        guard columns.range(of: #"^[lcr|\s]+$"#, options: .regularExpression) != nil else {
            throw TeXArchive.failure("表格列格式尚不支持")
        }
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        while !cursor.ended {
            if cursor.peek == "{" {
                cell += "{" + (try cursor.group()) + "}"
            } else if cursor.peek == "&" {
                row.append(cell)
                cell = ""
                cursor.index += 1
            } else if cursor.peek == "\\" {
                let start = cursor.index
                let command = cursor.command()
                if command == "\\" {
                    _ = try cursor.optional()
                    row.append(cell)
                    rows.append(row)
                    row = []
                    cell = ""
                } else if ["hline", "toprule", "midrule", "bottomrule"].contains(command) {
                    _ = try cursor.optional()
                } else if command == "cline" || command == "cmidrule" {
                    _ = try cursor.group()
                } else {
                    cell += String(cursor.characters[start..<cursor.index])
                }
            } else {
                cell.append(cursor.peek!)
                cursor.index += 1
            }
        }
        if !cell.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !row.isEmpty {
            row.append(cell)
            rows.append(row)
        }
        let count = columns.filter { "lcr".contains($0) }.count
        guard !rows.isEmpty, count > 0, rows.allSatisfy({ $0.count == count }) else {
            throw TeXArchive.failure("表格单元格结构不完整")
        }
        return "<table>"
            + (try rows.map { cells in
                "<tr>" + (try cells.map { "<td>" + (try render($0, inline: true)) + "</td>" }).joined() + "</tr>"
            }).joined() + "</table>"
    }

    private func anchor(_ label: String) -> String {
        "tex-" + SHA256.hash(data: Data(label.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func escape(_ text: String) -> String {
        HTMLPaperParser.escape(text).replacingOccurrences(of: "'", with: "&#39;")
    }
}
