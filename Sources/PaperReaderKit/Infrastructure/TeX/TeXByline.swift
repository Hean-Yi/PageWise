import Foundation

/// Standard author front matter is read locally. Unrecognized publisher markup remains inspectable as source.
struct TeXByline {
    private var parts: [String] = []

    mutating func append(_ value: String, mark: String?, author: Bool) {
        let marker = mark.map { "<sup>" + HTMLPaperParser.escape($0) + "</sup>" } ?? ""
        do {
            var cursor = TeXCursor(value)
            var namesFirst = author
            var row = ""
            var rows: [String] = []
            func finishRow() {
                let content = row.trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    let name = namesFirst ? "<span class='ltx_personname'>" + content + "</span>" : content
                    rows.append("<p>" + name + (rows.isEmpty ? marker : "") + "</p>")
                }
                row = ""
            }
            while !cursor.ended {
                if cursor.peek == "\\" {
                    let start = cursor.index
                    let command = cursor.command()
                    if ["and", "And", "AND", "\\"].contains(command) {
                        finishRow()
                        if command == "\\" { _ = try cursor.optional() }
                        namesFirst = author && command != "\\"
                        continue
                    }
                    if command == "thanks" {
                        let note = try Self.inline(cursor.group())
                        if !row.isEmpty { finishRow() }
                        rows.append("<p>" + note + "</p>")
                        namesFirst = false
                        continue
                    }
                    cursor.index = start
                }
                row += try Self.atom(&cursor)
            }
            finishRow()
            parts += rows
        } catch {
            let literal = HTMLPaperParser.escape(value)
            parts.append("<p>" + literal + marker + "</p>")
        }
    }

    var html: String {
        parts.isEmpty ? "" : "<div class='ltx_authors'>" + parts.joined() + "</div>"
    }

    private static func inline(_ value: String, depth: Int = 0) throws -> String {
        guard depth < 40 else { throw TeXArchive.failure("作者排版嵌套层级过深") }
        var cursor = TeXCursor(value)
        var html = ""
        while !cursor.ended { html += try atom(&cursor, depth: depth) }
        return html
    }

    private static func atom(_ cursor: inout TeXCursor, depth: Int = 0) throws -> String {
        guard let c = cursor.peek else { return "" }
        if c == "{" { return try inline(cursor.group(), depth: depth + 1) }
        if c == "$" {
            cursor.index += 1
            let source = try cursor.until("$")
            if let marker = source.wholeMatch(of: /(?:\{\})?\^\{?([0-9a-zA-Z*,†‡\s]+)\}?/) {
                return "<sup>" + HTMLPaperParser.escape(String(marker.1)) + "</sup>"
            }
            return HTMLPaperParser.escape("$" + source + "$")
        }
        if c != "\\" {
            cursor.index += 1
            return c == "~" ? " " : HTMLPaperParser.escape(String(c))
        }
        switch cursor.command() {
        case "texttt", "textrm", "textnormal", "textsf", "textit", "textbf", "emph", "url", "email":
            return try inline(cursor.group(), depth: depth + 1)
        case "textsuperscript", "inst":
            return try "<sup>" + inline(cursor.group(), depth: depth + 1) + "</sup>"
        case "href":
            _ = try cursor.group()
            return try inline(cursor.group(), depth: depth + 1)
        case "&": return "&amp;"
        case "_": return "_"
        case "%": return "%"
        case "#": return "#"
        case " ", ",", "quad", "qquad": return " "
        case "dag", "dagger": return "†"
        case "ddag", "ddagger": return "‡"
        default: throw TeXArchive.failure("作者署名含有出版方排版命令")
        }
    }
}
