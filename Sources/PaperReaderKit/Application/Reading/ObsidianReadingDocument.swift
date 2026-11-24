import Foundation

/// Publishes the AI notebook already synthesized during close reading, using the reader's latest edits.
public enum ObsidianReadingDocument {
    public static func markdown(paper: Paper, in state: LibraryState) throws -> String {
        var document = Document(paper: paper, state: state)
        return try document.render()
    }

    private struct Document {
        let paper: Paper
        let state: LibraryState
        let notes: [UUID: ReadingNote]
        var included = Set<UUID>()
        var annotationNumbers: [UUID: Int] = [:]
        private struct Excerpt: Hashable {
            let version: String?
            let pageKey: String
            let text: String
        }
        private var anchorNumbers: [Excerpt: Int] = [:]
        var referenceNumbers: [UUID: Int] = [:]
        var footnotes: [String] = []

        init(paper: Paper, state: LibraryState) {
            self.paper = paper
            self.state = state
            notes = Dictionary(state.readingNotes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }

        mutating func render() throws -> String {
            let runs = state.chats.reversed().filter { $0.paperID == paper.id && $0.closeReadingVersion != nil }
            var sections = ["## 论文信息\n\n" + (paper.sourceURL ?? "本地导入 PDF")]
            for (index, run) in runs.enumerated() {
                let date = run.createdAt.formatted(date: .abbreviated, time: .shortened)
                let heading = index == 0 ? "AI 精读" : "历史精读"
                var content = ["## \(heading) · \(date)"]
                if !run.question.isEmpty, run.question != "AI 精读" { content.append("精读重点：" + run.question) }
                if !run.answer.isEmpty { content.append(Self.quote(run.answer)) }
                if let id = run.readingNoteID, let summary = try reportNote(id), included.insert(id).inserted {
                    content.append(renderBody(summary))
                }
                var seen = Set<UUID>()
                var annotations: [String] = []
                for id in run.closeReadingNoteIDs ?? [] where seen.insert(id).inserted {
                    if let note = try reportNote(id) { annotations.append(annotation(note)) }
                }
                if !annotations.isEmpty {
                    content.append("### 段落批注\n\n" + annotations.joined(separator: "\n\n"))
                }
                sections.append(content.joined(separator: "\n\n"))
            }

            let remaining = state.readingNotes.filter {
                $0.paperID == paper.id && $0.deletedAt == nil && !included.contains($0.id) && !$0.markdown.isEmpty
            }
            if !remaining.isEmpty {
                var content = ["## 阅读笔记"]
                for note in remaining {
                    content.append(note.isDocumentSummary ? renderBody(note) : annotation(note))
                }
                sections.append(content.joined(separator: "\n\n"))
            }
            let marks = state.highlights.filter { $0.paperID == paper.id && !$0.text.isEmpty }.map { mark in
                let location = Self.location(key: mark.pageKey, version: mark.contentVersion, in: paper)
                let style = Self.color(mark.color ?? .yellow) + (mark.style == .underline ? "下划线" : "高亮")
                let version = mark.pageKey.hasPrefix("original-") ? paper.digest + ":original-0" : mark.contentVersion
                // PDF marks can predate text offsets. Retain a row per mark even if its page and text
                // match a note, while avoiding a second full copy of the same excerpt.
                if let number = anchorNumbers[Excerpt(version: version, pageKey: mark.pageKey, text: mark.text)] {
                    return "\(location) · \(style) · 摘录同批注 \(number)"
                }
                return "\(location) · \(style)\n\n" + Self.quote(mark.text)
            }
            if !marks.isEmpty { sections.append("## 划线批注\n\n" + marks.joined(separator: "\n\n")) }
            if !paper.summary.isEmpty { sections.append("## 论文总结\n\n" + paper.summary) }
            let dates = Set(
                state.reading.filter { $0.paperID == paper.id }.map { Calendar.current.startOfDay(for: $0.start) })
            if !dates.isEmpty {
                sections.append(
                    "## 阅读记录\n\n"
                        + dates.sorted().map { $0.formatted(date: .abbreviated, time: .omitted) }.joined(separator: "、")
                )
            }
            if !footnotes.isEmpty { sections.append(footnotes.joined(separator: "\n\n")) }
            return sections.joined(separator: "\n\n")
        }

        private func reportNote(_ id: UUID) throws -> ReadingNote? {
            guard let note = notes[id], note.paperID == paper.id else {
                throw ReaderError.message("精读报告关联的笔记记录不完整，请核对本地书库后重新整理。")
            }
            return note.deletedAt == nil ? note : nil
        }

        private mutating func annotation(_ note: ReadingNote) -> String {
            if let number = annotationNumbers[note.id] { return "此轮沿用批注 \(number)。" }
            included.insert(note.id)
            let number = annotationNumbers.count + 1
            annotationNumbers[note.id] = number
            let title = note.dimension.map { " · " + $0.title } ?? ""
            var content = ["#### 批注 \(number)\(title)"]
            for anchor in note.anchors {
                anchorNumbers[Excerpt(version: note.contentVersion, pageKey: anchor.key, text: anchor.text)] = number
                content.append(
                    Self.location(key: anchor.key, version: note.contentVersion, in: paper) + "\n\n"
                        + Self.quote(anchor.text))
            }
            content.append(renderBody(note))
            return content.joined(separator: "\n\n")
        }

        // Only links registered on this particular note can supply exported evidence. Other Markdown,
        // including formulas, ordinary hyperlinks and hand-written text, stays as the reader saved it.
        private static let internalLink = try! NSRegularExpression(
            pattern:
                #"(?s)(`+).*?\1|(?m:^ {0,3}(~{3,})[^\n]*\n.*?^ {0,3}\2~*[ \t]*$)|\[((?:\\.|[^\[\]\\])*)\]\(\s*<?(paperreader://passage/[0-9a-f-]+)>?\s*\)"#,
            options: .caseInsensitive)

        private mutating func renderBody(_ note: ReadingNote) -> String {
            guard let citations = note.citations, !citations.isEmpty else { return note.markdown }
            let original = note.markdown as NSString
            let body = NSMutableString(string: note.markdown)
            var replacements: [(NSRange, String)] = []
            for match in Self.internalLink.matches(
                in: note.markdown, range: NSRange(location: 0, length: original.length))
            {
                guard match.range(at: 4).location != NSNotFound else { continue }
                let destination = original.substring(with: match.range(at: 4))
                guard
                    let ref = citations.first(where: {
                        $0.url.absoluteString.caseInsensitiveCompare(destination) == .orderedSame
                    })
                else { continue }
                let source = evidence(ref)
                let number: Int
                if let prior = referenceNumbers[ref.id] {
                    number = prior
                } else {
                    number = footnotes.count + 1
                    referenceNumbers[ref.id] = number
                    footnotes.append("[^pr-\(number)]: " + source.text.replacingOccurrences(of: "\n", with: "\n    "))
                }
                // A deleted or rewritten source note can also have a quotation in its old link label.
                let label = source.available ? original.substring(with: match.range(at: 3)) : "来源待核对"
                replacements.append((match.range, "\(label)[^pr-\(number)]"))
            }
            for (range, value) in replacements.reversed() { body.replaceCharacters(in: range, with: value) }
            return body as String
        }

        private func evidence(_ ref: LocalPassageCitation) -> (available: Bool, text: String) {
            guard let source = state.papers.first(where: { $0.id == ref.paperID && $0.digest == ref.digest }) else {
                return (false, "所引论文已不在本地书库。")
            }
            if let id = ref.readingNoteID {
                guard let note = notes[id], note.paperID == source.id, note.contentVersion == ref.contentVersion,
                    note.deletedAt == nil, ReadingNoteMemoryIndex.searchableBody(note.markdown).contains(ref.quote)
                else { return (false, "《\(source.title)》的所引笔记已修改或删除。") }
                return (true, "《\(source.title)》 · 阅读笔记\n\n" + Self.quote(ref.quote))
            }
            guard source.id == paper.id, let first = ref.anchors.first else {
                return (false, "此处未登记可核对的本篇原文。")
            }
            return (
                true,
                Self.location(key: first.key, version: ref.contentVersion, in: source) + "\n\n" + Self.quote(ref.quote)
            )
        }

        private static func location(key: String, version: String?, in paper: Paper) -> String {
            let editions = ([paper.htmlReading] + (paper.retainedReadings ?? []).map(\.html)).compactMap { $0 }
            var isHTMLSection = false
            for edition in editions {
                guard let index = edition.sections.firstIndex(where: { $0.id.uuidString == key }) else { continue }
                isHTMLSection = true
                if version == nil || edition.readingNoteVersion(digest: paper.digest) == version {
                    return "源码第 \(index + 1) 段"
                }
            }
            if isHTMLSection { return "已保存的原文摘录" }
            if let position = PaperPageLocator.resolve(pageKey: key, in: paper) {
                if let source = PaperPageLocator.sourcePage(for: position, in: paper) { return "原文第 \(source + 1) 页" }
                if position.mode != "original" { return "重排第 \(position.pageIndex + 1) 页" }
            }
            return "已保存的原文摘录"
        }

        private static func color(_ color: AnnotationColor) -> String {
            switch color {
            case .yellow: "黄色"
            case .red: "红色"
            case .green: "绿色"
            case .blue: "蓝色"
            case .purple: "紫色"
            case .pink: "粉色"
            case .orange: "橙色"
            case .gray: "灰色"
            }
        }

        private static func quote(_ text: String) -> String {
            "> " + text.replacingOccurrences(of: "\n", with: "\n> ")
        }
    }
}
