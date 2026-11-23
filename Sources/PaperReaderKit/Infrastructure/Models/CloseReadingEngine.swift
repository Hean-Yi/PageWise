import Foundation

public enum CloseReadingEngine {
    private struct Quotation: Decodable {
        let source: String
        let quote: String
        let label: String?
    }

    private struct ProposedNote: Decodable {
        let dimension: CloseReadingDimension
        let source: String
        let quote: String
        let role: String
        let explanation: String
        let critique: String
        let references: [Quotation]?
    }

    private struct Stage: Decodable {
        let stage: CloseReadingStage
        let text: String
        let references: [Quotation]?
    }

    // Decode each array element independently. An unknown dimension or missing field in one
    // suggestion must not discard its neighbours. Malformed nested references still reject that item.
    private struct Record<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    private struct Batch: Decodable {
        let annotations: [Record<ProposedNote>]?
        let outline: [Record<Stage>]?
    }

    private enum ResponseIssue: Error {
        case format
    }

    private struct Input: Encodable {
        let source: String
        let paper: String
        let sourcePage: Int?
        let kind: String
        let anchorText: String
        let tableRows: String?

        init(_ passage: CloseReadingPassage) {
            source = passage.evidence.id
            paper = String(passage.evidence.title.prefix(360))
            sourcePage = passage.evidence.sourcePage.map { $0 + 1 }
            kind = passage.kind
            anchorText = passage.evidence.text
            tableRows = passage.table
        }
    }

    private struct Window: Encodable {
        let paper: String
        let focus: String
        let window: Int
        let windows: Int
        let passages: [Input]
        let readingNotes: [Input]
    }

    public static func run(
        paper: Paper, root: URL, focus: String = "",
        retrieveNotes: @Sendable (String) async throws -> [Evidence] = { _ in [] },
        progress: @Sendable (String) async -> Void,
        complete: @Sendable (_ system: String, _ user: String) async throws -> String
    ) async throws -> CloseReadingAnalysis {
        let corpus = try await CloseReadingCorpus.read(paper: paper, root: root, progress: progress)
        guard !corpus.windows.isEmpty else { throw ReaderError.message("这篇论文缺少可定位的本地原文，无法精读。") }
        var notes = [CloseReadingAnnotation]()
        var stages = [CloseReadingOutlineItem]()
        var rejected = 0
        var unreadable: [Int] = []
        var usedWindowOutline = false
        let name = String(paper.title.prefix(360))
        let focus = String(focus.prefix(1_600))
        for (index, passages) in corpus.windows.enumerated() {
            try Task.checkCancellation()
            await progress("正在精读第 \(index + 1) / \(corpus.windows.count) 组原文")
            let stride = max(1, passages.count / 5)
            let excerpts = passages.enumerated().filter { $0.offset.isMultiple(of: stride) }
                .prefix(5).map { String($0.element.evidence.text.prefix(200)) }
            let query = ([focus, name] + excerpts).joined(separator: " ")
            let memory = try await retrieveNotes(query).filter {
                $0.readingNoteID != nil && $0.paperID != nil && $0.paperID != paper.id && !$0.text.isEmpty
            }.prefix(5).enumerated().map { index, hit in
                var evidence = hit
                evidence.id = "L\(index + 1)"
                return CloseReadingPassage(evidence: evidence, kind: "readingNote", table: nil)
            }
            let input = Window(
                paper: name, focus: focus, window: index + 1, windows: corpus.windows.count,
                passages: passages.map(Input.init), readingNotes: memory.map(Input.init))
            let batch: Batch
            do {
                batch = try await request(
                    prompt: windowPrompt, input: try json(input), progress: progress,
                    retryLabel: "正在重新核对第 \(index + 1) 组的返回格式", complete: complete,
                    validate: { batch in
                        let records = (batch.annotations?.count ?? 0) + (batch.outline?.count ?? 0)
                        return (batch.annotations != nil || batch.outline != nil)
                            && (records == 0 || batch.annotations?.contains { $0.value != nil } == true
                                || batch.outline?.contains { $0.value != nil } == true)
                    })
            } catch ResponseIssue.format {
                unreadable.append(index + 1)
                continue
            }
            let registry = Dictionary(uniqueKeysWithValues: (passages + memory).map { ($0.evidence.id, $0) })
            // Both the source ID and the exact quotation must match the locally registered window.
            for record in (batch.annotations ?? []).prefix(8) {
                guard let item = record.value, let passage = registry[item.source],
                    passage.evidence.paperID == paper.id,
                    let quote = exact(item.quote, in: passage), let role = plain(item.role, limit: 360),
                    let explanation = plain(item.explanation, limit: 1_400),
                    let critique = plain(item.critique, limit: 1_400)
                else {
                    rejected += 1
                    continue
                }
                let requested = item.references ?? []
                let linked = requested.prefix(4).compactMap { citation($0, in: registry) }
                guard linked.count == requested.count else {
                    rejected += 1
                    continue
                }
                let extra =
                    linked
                    .filter { $0.evidence.id != passage.evidence.id || $0.quote != quote }
                let evidence = [passage.evidence.text, tableEvidence(passage)] + extra.map(\.quote)
                guard
                    numbersAreGrounded(
                        [role, explanation, critique].joined(separator: "\n"),
                        in: evidence.joined(separator: "\n"))
                else {
                    rejected += 1
                    continue
                }
                if notes.contains(where: {
                    $0.source.blockID == passage.evidence.blockID && $0.source.sourcePage == passage.evidence.sourcePage
                        && $0.quote == quote
                }) {
                    continue
                }
                let body = "**段落作用**　" + role + "\n\n" + explanation + "\n\n**审读**　" + critique
                notes.append(
                    .init(
                        dimension: item.dimension, source: passage.evidence, quote: quote, markdown: body,
                        references: extra))
            }
            for record in (batch.outline ?? []).prefix(10) {
                guard let item = record.value else { continue }
                let requested = item.references ?? []
                let refs = requested.prefix(3).compactMap { citation($0, in: registry) }
                guard refs.count == requested.count else { continue }
                guard let text = plain(item.text, limit: 720), refs.contains(where: { $0.evidence.paperID == paper.id })
                else { continue }
                let proof = refs.map { $0.quote + "\n" + (registry[$0.evidence.id].map(tableEvidence) ?? "") }.joined(
                    separator: "\n")
                guard numbersAreGrounded(text, in: proof) else { continue }
                let ordered =
                    refs.filter { $0.evidence.paperID == paper.id } + refs.filter { $0.evidence.paperID != paper.id }
                stages.append(.init(stage: item.stage, text: text, references: ordered))
            }
        }
        if corpus.windows.count > 1 && (!notes.isEmpty || !stages.isEmpty) {
            try Task.checkCancellation()
            await progress("正在串联全文论证，复核结论的适用范围")
            do {
                (notes, stages) = try await synthesize(
                    notes: notes, stages: stages, paper: name, focus: focus, progress: progress, complete: complete)
            } catch ResponseIssue.format {
                usedWindowOutline = true
            }
        }
        guard !notes.isEmpty || !stages.isEmpty else {
            if !unreadable.isEmpty {
                throw ReaderError.message(
                    "第 " + unreadable.map(String.init).joined(separator: "、")
                        + " 组的模型返回格式在重试后仍不完整，其余材料未产生可定位的精读结果。")
            }
            throw ReaderError.message("已检查原文，但模型没有返回能逐字定位的批注或论证依据。")
        }
        let outline = CloseReadingStage.allCases.map { stage in
            stages.first { $0.stage == stage }
                ?? .init(stage: stage, text: "已读材料中未定位到明确的\(stage.title)依据。", references: [])
        }
        var coverage = corpus.coverage
        if !unreadable.isEmpty {
            coverage = coverage.replacingOccurrences(
                of: "已分析\(corpus.windows.count)/", with: "已分析\(corpus.windows.count - unreadable.count)/")
            coverage += " · 第 " + unreadable.map(String.init).joined(separator: "、") + " 组返回格式不完整，未计入精读结果"
        }
        if usedWindowOutline { coverage += " · 全文归纳返回格式不完整，采用分组核实的批注和论证环节" }
        if rejected > 0 { coverage += " · \(rejected)条候选批注未通过原文或格式核对" }
        return .init(annotations: notes, outline: outline, coverage: coverage)
    }

    private static func exact(_ raw: String, in passage: CloseReadingPassage) -> String? {
        let quote = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty, quote.count <= 1_500, quote.last != "-", quote.last != "\u{00AD}" else { return nil }
        let source = passage.evidence.text
        if source.contains(quote) { return quote }
        // Recover the original spelling of whitespace, never the model's paraphrase.
        let pattern = quote.split(whereSeparator: \.isWhitespace).map {
            NSRegularExpression.escapedPattern(for: String($0))
        }.joined(separator: #"\s+"#)
        guard let match = source.range(of: pattern, options: .regularExpression) else { return nil }
        return String(source[match])
    }

    private static func citation(_ item: Quotation, in registry: [String: CloseReadingPassage])
        -> CloseReadingReference?
    {
        guard let passage = registry[item.source], let quote = exact(item.quote, in: passage) else { return nil }
        return .init(
            evidence: passage.evidence, quote: quote,
            label: item.label.flatMap { plain($0, limit: 80) } ?? passage.evidence.title)
    }

    // Links are constructed by the app after checking evidence. Free prose cannot introduce
    // a URL, a Markdown target, or HTML that behaves differently from its displayed label.
    private static func plain(_ raw: String, limit: Int) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= limit,
            text.range(
                of:
                    #"(?i)(?:[a-z][a-z0-9+.\-]*://|mailto:|javascript:|data:|www\.|\]\s*[\(\[]|^\s*\[[^\]]+\]\s*:|<[a-z!/])"#,
                options: [.regularExpression]) == nil
        else { return nil }
        return text
    }

    /// A result's numerical statements must be available in the supplied text or registered rows.
    /// In particular, a figure caption is not a source of pixel measurements or p-values.
    private static let number = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z\d.])[-+]?\d+(?:[.,]\d+)*(?:[eE][+-]?\d+)?%?(?![A-Za-z\d])"#)

    private static func numbersAreGrounded(_ text: String, in evidence: String) -> Bool {
        func normalized(_ value: String) -> String {
            value.replacingOccurrences(of: "％", with: "%").replacingOccurrences(of: "−", with: "-")
        }
        func canonical(_ value: String) -> String {
            let isPercent = value.hasSuffix("%")
            var digits = (isPercent ? String(value.dropLast()) : value).replacingOccurrences(of: ",", with: "")
            if let parsed = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")) {
                digits = NSDecimalNumber(decimal: parsed).stringValue
            }
            return digits + (isPercent ? "%" : "")
        }
        func values(_ value: String) -> Set<String> {
            let value = normalized(value)
            return Set(
                number.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                    canonical((value as NSString).substring(with: $0.range))
                })
        }
        let proof = values(evidence)
        let value = normalized(text)
        let mutable = NSMutableString(string: value)
        // A percentage-point difference can be verified when the same sentence states both
        // independently sourced percentages and the exact base-ten subtraction matches.
        for match in percentageDifference.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed()
        {
            let ns = value as NSString
            let operands = (1...3).map { ns.substring(with: match.range(at: $0)) }
            if proof.contains(canonical(operands[0] + "%")), proof.contains(canonical(operands[1] + "%")),
                let a = Decimal(string: operands[0]), let b = Decimal(string: operands[1]),
                let d = Decimal(string: operands[2]),
                abs(b - a) == d
            {
                mutable.replaceCharacters(in: match.range(at: 3), with: "")
            } else {
                return false
            }
        }
        return values(mutable as String).isSubset(of: proof)
    }

    private static let percentageDifference = try! NSRegularExpression(
        pattern:
            #"(\d+(?:\.\d+)?)%[^。.!?；;\d%\n]{1,24}(\d+(?:\.\d+)?)%[^。.!?；;\d%\n]{1,26}(\d+(?:\.\d+)?)\s*(?:个?百分点|percentage points)"#,
        options: [.caseInsensitive])

    /// A percent-marked leaf column supplies the unit for each value in that column alone.
    private static func tableEvidence(_ passage: CloseReadingPassage) -> String {
        guard let table = passage.table else { return "" }
        let rows = table.components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
        guard let head = rows.first else { return table }
        let columns = head.indices.filter { head[$0].contains("%") || head[$0].contains("％") }
        let percentages = rows.dropFirst().flatMap { row in
            columns.compactMap { index -> String? in
                guard index < row.count, row[index].wholeMatch(of: /[+-]?\d+(?:\.\d+)?/) != nil else { return nil }
                return row[index] + "%"
            }
        }
        return table + "\n" + percentages.joined(separator: " ")
    }

    private struct SynthesisCandidate: Encodable {
        let id: String
        let stage: String?
        let dimension: String?
        let summary: String
        let quotes: [String]
    }

    private struct SynthesisInput: Encodable {
        let paper: String
        let focus: String
        let annotations: [SynthesisCandidate]
        let outlineEvidence: [SynthesisCandidate]
    }

    private struct SynthesisOutput: Decodable {
        struct Item: Decodable {
            let stage: CloseReadingStage
            let text: String
            let witnesses: [String]
        }
        let keep: [String]?
        let outline: [Record<Item>]?

    }

    private static func synthesize(
        notes: [CloseReadingAnnotation], stages: [CloseReadingOutlineItem], paper: String,
        focus: String, progress: @Sendable (String) async -> Void,
        complete: @Sendable (String, String) async throws -> String
    ) async throws
        -> ([CloseReadingAnnotation], [CloseReadingOutlineItem])
    {
        let candidates = notes.enumerated().map { i, note in
            SynthesisCandidate(
                id: "N\(i + 1)", stage: nil, dimension: note.dimension.rawValue,
                summary: String(note.markdown.prefix(170)), quotes: [String(note.quote.prefix(110))])
        }
        let witnesses = stages.enumerated().map { i, stage in
            SynthesisCandidate(
                id: "W\(i + 1)", stage: stage.stage.rawValue, dimension: nil,
                summary: String(stage.text.prefix(130)),
                quotes: stage.references.prefix(1).map { String($0.quote.prefix(110)) })
        }
        let input = SynthesisInput(paper: paper, focus: focus, annotations: candidates, outlineEvidence: witnesses)
        let known = Set(candidates.map(\.id))
        let result: SynthesisOutput = try await request(
            prompt: synthesisPrompt, input: try json(input), progress: progress, retryLabel: "正在重新核对全文归纳格式",
            complete: complete,
            validate: { result in
                let selected = result.keep ?? []
                return (result.keep != nil || result.outline != nil)
                    && (known.isEmpty || selected.contains(where: known.contains))
            })
        let ids = Set((result.keep ?? []).prefix(24))
        let selected = zip(notes, candidates).filter { ids.contains($0.1.id) }.map { $0.0 }
        let lookup = Dictionary(uniqueKeysWithValues: zip(witnesses.map(\.id), stages))
        let outline = (result.outline ?? []).prefix(10).compactMap { record -> CloseReadingOutlineItem? in
            guard let item = record.value else { return nil }
            let supporting = item.witnesses.prefix(3).compactMap { lookup[$0] }
            guard supporting.count == item.witnesses.count, !supporting.isEmpty,
                supporting.allSatisfy({ $0.stage == item.stage }), let text = plain(item.text, limit: 720),
                numbersAreGrounded(
                    text,
                    in: supporting.map { $0.text + " " + $0.references.map(\.quote).joined(separator: " ") }.joined(
                        separator: " "))
            else { return nil }
            let refs = supporting.compactMap { $0.references.first }
            return .init(stage: item.stage, text: text, references: refs)
        }
        // Fall back only to an already verified account of that stage, never to unregistered witnesses.
        return (selected, outline + stages.filter { local in !outline.contains { $0.stage == local.stage } })
    }

    private static func json<T: Encodable>(_ object: T) throws -> String {
        String(decoding: try JSONEncoder().encode(object), as: UTF8.self)
    }

    private static func request<T: Decodable>(
        prompt: String, input: String, progress: @Sendable (String) async -> Void, retryLabel: String,
        complete: @Sendable (String, String) async throws -> String, validate: (T) -> Bool
    ) async throws -> T {
        for attempt in 0...1 {
            try Task.checkCancellation()
            if attempt == 1 { await progress(retryLabel) }
            let instruction =
                attempt == 0
                ? prompt
                : prompt + """

                    上一次返回的结构未通过本地 JSON 校验。请按同一协议用双引号输出单个完整 JSON 对象，每个数组最多三项，只选关键证据，缩短引文与说明。省略缺少依据的条目，务必闭合所有括号，不要附加 Markdown。
                    """
            let raw: String
            do {
                raw = try await complete(instruction, input)
            } catch is ModelClient.TruncatedCompletion {
                try Task.checkCancellation()
                continue
            }
            try Task.checkCancellation()
            if raw.utf8.count <= 180_000, let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
                start <= end, let decoded = try? JSONDecoder().decode(T.self, from: Data(raw[start...end].utf8)),
                validate(decoded)
            {
                return decoded
            }
        }
        throw ResponseIssue.format
    }
}
