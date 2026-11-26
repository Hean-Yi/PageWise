import Foundation

public struct CloseReadingCheckpoint: Codable, Sendable {
    public let version: String
    public let focus: String
    let totalWindows: Int
    let coverage: String
    var completedWindows: Int
    var notes: [CloseReadingAnnotation]
    var seenAnalyses: [String]
    var stages: [CloseReadingOutlineItem]
    var supplementaryWindows: Int
    var missedSupplement: Int
    var annotatedSources: [String]
    var rejected: Int
    var skippedWindows: [String: [Int]]
}

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
        let analysis: String
        let references: [Quotation]?
    }

    private struct Stage: Decodable {
        let stage: CloseReadingStage
        let text: String
        let references: [Quotation]?
    }

    // Decode each array element independently. An unknown dimension or missing field in one
    // suggestion must not discard its neighbours. Malformed nested references still reject that item.
    struct Record<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    private struct Batch: Decodable {
        let annotations: [Record<ProposedNote>]?
        let outline: [Record<Stage>]?
    }

    enum ResponseIssue: String, Error, CaseIterable {
        case format, outputLimit

        var description: String {
            switch self {
            case .format: "未通过格式或依据核对"
            case .outputLimit: "达到模型输出长度上限"
            }
        }
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
        let alreadyDiscussed: [String]
    }

    public static func run(
        paper: Paper, root: URL, focus: String = "", version: String = "",
        checkpoint: CloseReadingCheckpoint? = nil,
        onCheckpoint: (@Sendable (CloseReadingCheckpoint) async -> Void)? = nil,
        retrieveNotes: @Sendable (String) async throws -> [Evidence] = { _ in [] },
        progress: @Sendable (String) async -> Void,
        complete: @Sendable (_ system: String, _ user: String) async throws -> String
    ) async throws -> CloseReadingAnalysis {
        let corpus = try await CloseReadingCorpus.read(paper: paper, root: root, progress: progress)
        guard !corpus.windows.isEmpty else { throw ReaderError.message("这篇论文缺少可定位的本地原文，无法精读。") }
        let name = String(paper.title.prefix(360))
        let focus = String(focus.prefix(1_600))
        let resumable =
            checkpoint.flatMap { saved in
                saved.version == version && saved.focus == focus
                    && saved.totalWindows == corpus.windows.count
                    && saved.coverage == corpus.coverage
                    && (0...corpus.windows.count).contains(saved.completedWindows) ? saved : nil
            }
        var notes = resumable?.notes ?? [CloseReadingAnnotation]()
        var seenAnalyses = Set(resumable?.seenAnalyses ?? [])
        var stages = resumable?.stages ?? [CloseReadingOutlineItem]()
        var supplementaryWindows = resumable?.supplementaryWindows ?? 0
        var missedSupplement = resumable?.missedSupplement ?? 0
        var annotatedSources = Set(resumable?.annotatedSources ?? [])
        var rejected = resumable?.rejected ?? 0
        var skippedWindows: [ResponseIssue: [Int]] = [:]
        if let savedSkips = resumable?.skippedWindows {
            for (raw, list) in savedSkips {
                if let issue = ResponseIssue(rawValue: raw) { skippedWindows[issue] = list }
            }
        }
        var fallbackReason: ResponseIssue?
        let startWindow = resumable?.completedWindows ?? 0
        for index in startWindow..<corpus.windows.count {
            let passages = corpus.windows[index]
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
                passages: passages.map(Input.init), readingNotes: memory.map(Input.init),
                alreadyDiscussed: notes.suffix(8).map { String($0.markdown.prefix(180)) })
            let batch: Batch
            do {
                batch = try await request(
                    prompt: windowPrompt, input: try json(input), progress: progress,
                    retryLabel: "正在重新核对第 \(index + 1) 组的返回格式", complete: complete,
                    accept: { (batch: Batch) in
                        let records = (batch.annotations?.count ?? 0) + (batch.outline?.count ?? 0)
                        guard batch.annotations != nil || batch.outline != nil,
                            records == 0 || batch.annotations?.contains(where: { $0.value != nil }) == true
                                || batch.outline?.contains(where: { $0.value != nil }) == true
                        else { return nil }
                        return batch
                    })
            } catch let issue as ResponseIssue {
                skippedWindows[issue, default: []].append(index + 1)
                if let onCheckpoint {
                    let nextCheckpoint = CloseReadingCheckpoint(
                        version: version, focus: focus, totalWindows: corpus.windows.count,
                        coverage: corpus.coverage, completedWindows: index + 1, notes: notes,
                        seenAnalyses: Array(seenAnalyses), stages: stages,
                        supplementaryWindows: supplementaryWindows, missedSupplement: missedSupplement,
                        annotatedSources: Array(annotatedSources), rejected: rejected,
                        skippedWindows: Dictionary(
                            uniqueKeysWithValues: skippedWindows.map { ($0.key.rawValue, $0.value) }))
                    await onCheckpoint(nextCheckpoint)
                }
                continue
            }
            let registry = Dictionary(uniqueKeysWithValues: (passages + memory).map { ($0.evidence.id, $0) })
            let priorCount = notes.count
            func registerAnnotations(_ batch: Batch) {
                // Both the source ID and the exact quotation must match the locally registered window.
                for record in (batch.annotations ?? []).prefix(12) {
                    guard let item = record.value, let passage = registry[item.source],
                        passage.evidence.paperID == paper.id,
                        let quote = exact(item.quote, in: passage), let body = plain(item.analysis, limit: 1_400)
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
                    let evidence =
                        [passage.evidence.text, tableEvidence(passage)]
                        + extra.map {
                            $0.quote + "\n" + (registry[$0.evidence.id].map(tableEvidence) ?? "")
                        }
                    guard numbersAreGrounded(body, in: evidence.joined(separator: "\n")) else {
                        rejected += 1
                        continue
                    }
                    // Leave one new insight per registered passage. Preserve numbers and mathematical
                    // symbols when comparing prose: two results can differ only by a sign.
                    let analysis = readerProse(body, citing: linked.map(\.evidence) + [passage.evidence])
                    let key = analysis.filter { !$0.isWhitespace }.lowercased()
                    if annotatedSources.contains(passage.evidence.id) || !seenAnalyses.insert(key).inserted {
                        continue
                    }
                    annotatedSources.insert(passage.evidence.id)
                    notes.append(
                        .init(
                            dimension: item.dimension, source: passage.evidence, quote: quote, markdown: analysis,
                            references: extra))
                }
            }
            registerAnnotations(batch)
            // Only revisit substantial windows with unusually thin coverage. Bound the extra
            // work for long papers and leave bibliographies or legitimately empty windows alone.
            let substantive = passages.filter { $0.table != nil || $0.evidence.text.count >= 180 }
            if supplementaryWindows < 2, substantive.count >= 6, notes.count - priorCount < 3,
                !(batch.annotations ?? []).isEmpty || !(batch.outline ?? []).isEmpty
            {
                supplementaryWindows += 1
                let remaining = passages.filter { !annotatedSources.contains($0.evidence.id) }
                let supplement = Window(
                    paper: name, focus: focus, window: index + 1, windows: corpus.windows.count,
                    passages: remaining.map(Input.init), readingNotes: memory.map(Input.init),
                    alreadyDiscussed: notes.suffix(8).map { String($0.markdown.prefix(180)) })
                await progress("正在复核第 \(index + 1) 组尚未标注的依据")
                do {
                    let extra = try await request(
                        prompt: windowPrompt + "\n本次只补读未标注的原文。选择能改变判断的机制、对照或失效条件；所给材料没有新信息时返回空数组。outline 留空。",
                        input: try json(supplement), progress: progress, retryLabel: "", attempts: 1,
                        complete: complete,
                        accept: { (value: Batch) in value.annotations == nil ? nil : value })
                    registerAnnotations(extra)
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        throw CancellationError()
                    }
                    missedSupplement += 1
                }
            }
            for record in (batch.outline ?? []).prefix(10) {
                guard let item = record.value else { continue }
                let requested = item.references ?? []
                let refs = requested.prefix(3).compactMap { citation($0, in: registry) }
                guard refs.count == requested.count else { continue }
                guard let text = plain(item.text, limit: 720), !refs.isEmpty,
                    refs.allSatisfy({ $0.evidence.paperID == paper.id })
                else { continue }
                let proof = refs.map { $0.quote + "\n" + (registry[$0.evidence.id].map(tableEvidence) ?? "") }.joined(
                    separator: "\n")
                guard numbersAreGrounded(text, in: proof) else { continue }
                stages.append(
                    .init(stage: item.stage, text: readerProse(text, citing: refs.map(\.evidence)), references: refs))
            }
            if let onCheckpoint {
                let nextCheckpoint = CloseReadingCheckpoint(
                    version: version, focus: focus, totalWindows: corpus.windows.count,
                    coverage: corpus.coverage, completedWindows: index + 1, notes: notes,
                    seenAnalyses: Array(seenAnalyses), stages: stages,
                    supplementaryWindows: supplementaryWindows, missedSupplement: missedSupplement,
                    annotatedSources: Array(annotatedSources), rejected: rejected,
                    skippedWindows: Dictionary(
                        uniqueKeysWithValues: skippedWindows.map { ($0.key.rawValue, $0.value) }))
                await onCheckpoint(nextCheckpoint)
            }
        }
        let incomplete = ResponseIssue.allCases.compactMap { issue -> String? in
            guard let windows = skippedWindows[issue] else { return nil }
            return "第 " + windows.map(String.init).joined(separator: "、") + " 组在重试后仍" + issue.description
        }.joined(separator: "；")
        guard !notes.isEmpty || !stages.isEmpty else {
            if !incomplete.isEmpty {
                throw ReaderError.message(incomplete + "，其余材料未产生可定位的精读结果。")
            }
            throw ReaderError.message("已检查原文，但模型没有返回能逐字定位的批注或论证依据。")
        }
        try Task.checkCancellation()
        await progress("正在撰写文末阅读笔记，核对方法、证据与解读")
        let sources = Dictionary(uniqueKeysWithValues: corpus.windows.joined().map { ($0.evidence.id, $0) })
        let sections: [CloseReadingNotebookSection]
        var rejectedSections = 0
        var partialSections = 0
        var repairDiagnostic: String?
        do {
            (sections, rejectedSections, partialSections, repairDiagnostic) = try await synthesize(
                notes: notes, stages: stages, passages: sources, paper: name, focus: focus, coverage: corpus.coverage,
                progress: progress, complete: complete)
        } catch let issue as ResponseIssue {
            fallbackReason = issue
            sections = verifiedExcerpts(notes, stages: stages)
        }
        var coverage = corpus.coverage
        if !incomplete.isEmpty {
            let skipped = skippedWindows.values.reduce(0) { $0 + $1.count }
            coverage = coverage.replacingOccurrences(
                of: "已分析\(corpus.windows.count)/", with: "已分析\(corpus.windows.count - skipped)/")
            coverage += " · " + incomplete + "，未计入精读结果"
        }
        if let fallbackReason {
            coverage += " · 文末写作重试后仍" + fallbackReason.description + "，采用分组核实的批注和论证环节"
        }
        if missedSupplement > 0 { coverage += " · \(missedSupplement) 组补读未完成，保留初读结果" }
        if let repairDiagnostic { coverage += " · " + repairDiagnostic }
        if partialSections > 0 { coverage += " · \(partialSections) 节仅保留已核对段落" }
        if rejectedSections > 0 { coverage += " · \(rejectedSections) 节文末解读未通过格式或依据核对" }
        if rejected > 0 { coverage += " · \(rejected)条候选批注未通过原文或格式核对" }
        return .init(annotations: notes, sections: sections, coverage: coverage)
    }

    /// If the provider could not finish the notebook, the already checked commentary
    /// is still readable. Keep each passage's analysis beside its own evidence.
    private static func verifiedExcerpts(_ notes: [CloseReadingAnnotation], stages: [CloseReadingOutlineItem])
        -> [CloseReadingNotebookSection]
    {
        var sections = [CloseReadingNotebookSection]()
        var discussed = Set<String>()
        for note in notes {
            let source = CloseReadingReference(evidence: note.source, quote: note.quote, label: "批注原文")
            sections.append(
                .init(heading: note.dimension.title, markdown: note.markdown, references: [source] + note.references))
            discussed.insert(note.source.id)
        }
        for stage in stages where stage.references.contains(where: { !discussed.contains($0.evidence.id) }) {
            sections.append(.init(heading: stage.stage.title, markdown: stage.text, references: stage.references))
        }
        return sections
    }

    private static func exact(_ raw: String, in passage: CloseReadingPassage) -> String? {
        let quote = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty, quote.count <= 1_500, quote.last != "-", quote.last != "\u{00AD}" else { return nil }
        let source = passage.evidence.text
        if passage.kind == "equation" {
            // An equation object has one stable anchor; a matching term inside it does not.
            return quote == source || "[公式] " + quote == source ? source : nil
        }
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

    // Models sometimes repeat a transport ID in their prose even when supplying the citation.
    // Keep genuine paper terminology (e.g. a condition called P2) and let the UI link the sources.
    private static let sourceMention = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])([PL]\d+)(?![A-Za-z0-9_])"#)

    private static func readerProse(_ text: String, citing sources: [Evidence]) -> String {
        let original = text as NSString
        let result = NSMutableString(string: text)
        for match in sourceMention.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
            let id = original.substring(with: match.range)
            guard let source = sources.first(where: { $0.id == id }),
                !sources.contains(where: { $0.text.contains(id) })
            else { continue }
            result.replaceCharacters(in: match.range, with: source.readingNoteID == nil ? "原文" : "此前的笔记")
        }
        return result as String
    }

    // Links are constructed by the app after checking evidence. Free prose cannot introduce
    // a URL, a Markdown target, or HTML that behaves differently from its displayed label.
    static func plain(_ raw: String, limit: Int) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= limit,
            text.range(
                of:
                    #"(?i)(?:[a-z][a-z0-9+.\-]*://|mailto:|javascript:|data:|www\.|\]\s*[\(\[]|^\s*\[[^\]]+\]\s*:|</?[a-z][a-z0-9:-]*(?:\s[^>]*)?/?>|<!|!\[\[)"#,
                options: [.regularExpression]) == nil
        else { return nil }
        return text
    }

    /// A result's numerical statements must be available in the supplied text or registered rows.
    /// In particular, a figure caption is not a source of pixel measurements or p-values.
    private static let number = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z\d.])[-+]?\d+(?:[.,]\d+)*(?:[eE][+-]?\d+)?%?(?![A-Za-z\d])"#)

    private static func normalizedNumbers(_ value: String) -> String {
        value.replacingOccurrences(of: "％", with: "%").replacingOccurrences(of: "\\%", with: "%")
            .replacingOccurrences(of: "−", with: "-")
    }
    private static func canonicalNumber(_ value: String) -> String {
        let isPercent = value.hasSuffix("%")
        var digits = (isPercent ? String(value.dropLast()) : value).replacingOccurrences(of: ",", with: "")
        if let parsed = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")) {
            digits = NSDecimalNumber(decimal: parsed).stringValue
        }
        return digits + (isPercent ? "%" : "")
    }
    private static func numberValues(_ value: String) -> Set<String> {
        let value = normalizedNumbers(value)
        return Set(
            number.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                canonicalNumber((value as NSString).substring(with: $0.range))
            })
    }

    private static func numericProse(_ text: String) -> String {
        // Numbered Markdown steps are note structure; compare only substantive numbers to the source.
        text.replacingOccurrences(
            of:
                #"(?m)^([ \t]*(?:>[ \t]*)*(?:#{1,6}[ \t]+)?(?:\*\*)?)(?:\d{1,3}[.)][ \t]+|第[ \t]*\d{1,3}[ \t]*步[ \t]*[：:、][ \t]*)"#,
            with: "$1", options: .regularExpression)
    }

    // A locator may be translated between English and Chinese. Its digits identify an
    // object, and cannot also substantiate a measurement in the notebook.
    private static let objectLabel = try! NSRegularExpression(
        pattern:
            #"(?i)(?<![a-z])(?:(table|表)|(figure|fig\.?|图))[ \t]*([0-9]+(?:\.[0-9]+)*)(?:[ \t]*[(（]([a-z])[)）]|([a-z]))?(?![a-z0-9])"#
    )

    private static func separatingObjectLabels(_ text: String) -> (prose: String, labels: Set<String>) {
        let source = text as NSString
        let matches = objectLabel.matches(in: text, range: NSRange(location: 0, length: source.length))
        let prose = NSMutableString(string: text)
        var labels = Set<String>()
        for match in matches.reversed() {
            let kind = match.range(at: 1).location == NSNotFound ? "Figure " : "Table "
            let suffix =
                [4, 5].first { match.range(at: $0).location != NSNotFound }
                .map { source.substring(with: match.range(at: $0)).lowercased() } ?? ""
            labels.insert(kind + source.substring(with: match.range(at: 3)) + suffix)
            prose.replaceCharacters(in: match.range, with: " ")
        }
        return (prose as String, labels)
    }

    static func unreportedNumberLiterals(_ text: String, in evidence: String) -> [String] {
        let requested = separatingObjectLabels(numericProse(text))
        let cited = separatingObjectLabels(evidence)
        let missing = numberValues(requested.prose).subtracting(numberValues(cited.prose))
        return Array(missing.union(requested.labels.subtracting(cited.labels)).sorted().prefix(24))
    }

    static func numbersAreGrounded(_ text: String, in evidence: String) -> Bool {
        let requested = separatingObjectLabels(numericProse(text))
        let cited = separatingObjectLabels(evidence)
        guard requested.labels.isSubset(of: cited.labels) else { return false }
        let evidence = cited.prose
        let proof = numberValues(evidence)
        let prose = requested.prose
        let value = normalizedNumbers(prose)
        let mutable = NSMutableString(string: value)
        // A percentage-point difference can be verified when the same sentence states both
        // independently sourced percentages and the exact base-ten subtraction matches.
        for match in percentageDifference.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed()
        {
            let ns = value as NSString
            let operands = (1...3).map { ns.substring(with: match.range(at: $0)) }
            if proof.contains(canonicalNumber(operands[0] + "%")), proof.contains(canonicalNumber(operands[1] + "%")),
                let a = Decimal(string: operands[0]), let b = Decimal(string: operands[1]),
                let d = Decimal(string: operands[2]),
                abs(b - a) == d
            {
                mutable.replaceCharacters(in: match.range(at: 3), with: "")
            } else {
                return false
            }
        }
        // A note comparing two controlled experiments can mention just the gaps. Accept each
        // percentage-point gap only if one registered excerpt gives an unambiguous percentage pair.
        // Combining numbers from different excerpts or computing arbitrary scalar differences
        // would also validate unrelated outcomes.
        var pairedDifferences = Set<Decimal>()
        for excerpt in evidence.split(separator: "\n") {
            let percents = numberValues(String(excerpt)).filter { $0.hasSuffix("%") }
            guard percents.count == 2 else { continue }
            let pair = percents.compactMap {
                Decimal(string: String($0.dropLast()), locale: Locale(identifier: "en_US_POSIX"))
            }
            if pair.count == 2 { pairedDifferences.insert(abs(pair[0] - pair[1])) }
        }
        let sources = normalizedNumbers(evidence) as NSString
        let reported = Set(
            percentagePointValue.matches(in: sources as String, range: NSRange(location: 0, length: sources.length)).map
            {
                canonicalNumber(sources.substring(with: $0.range(at: 1)))
            })
        let remainder = mutable as String
        for match in percentagePointValue.matches(in: remainder, range: NSRange(remainder.startIndex..., in: remainder))
            .reversed()
        {
            let digits = (remainder as NSString).substring(with: match.range(at: 1))
            if let value = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")),
                pairedDifferences.contains(value)
            {
                mutable.replaceCharacters(in: match.range(at: 1), with: "")
            } else if !reported.contains(canonicalNumber(digits)) {
                return false
            }
        }
        return numberValues(mutable as String).isSubset(of: proof)
    }

    private static let percentageDifference = try! NSRegularExpression(
        pattern:
            #"(\d+(?:\.\d+)?)%[^。.!?；;\d%\n]{1,24}(\d+(?:\.\d+)?)%[^。.!?；;\d%\n]{1,26}(\d+(?:\.\d+)?)\s*(?:个?百分点|percentage points)"#,
        options: [.caseInsensitive])

    private static let percentagePointValue = try! NSRegularExpression(
        pattern: #"(?<![\d.])(\d+(?:\.\d+)?)\s*(?:个?百分点|percentage points?)"#, options: [.caseInsensitive])

    /// A percent-marked leaf column supplies the unit for each value in that column alone.
    static func tableEvidence(_ passage: CloseReadingPassage) -> String {
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

    static func json<T: Encodable>(_ object: T) throws -> String {
        String(decoding: try JSONEncoder().encode(object), as: UTF8.self)
    }

    static func request<T: Decodable, Output>(
        prompt: String, input: String, progress: @Sendable (String) async -> Void, retryLabel: String,
        attempts: Int = 2,
        complete: @Sendable (String, String) async throws -> String, accept: (T) -> Output?
    ) async throws -> Output {
        var issue = ResponseIssue.format
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            if attempt > 0 { await progress(retryLabel) }
            let instruction =
                attempt == 0
                ? prompt
                : prompt + """

                    上一次\(issue.description)。请按同一协议用双引号输出单个完整 JSON 对象，精简重复引文与重复解读，优先保留有依据的关键方法、实验和边界。务必闭合所有括号，Markdown 内容只写在指定字符串中。
                    """
            let raw: String
            do {
                raw = try await complete(instruction, input)
            } catch is ModelClient.TruncatedCompletion {
                issue = .outputLimit
                try Task.checkCancellation()
                continue
            }
            try Task.checkCancellation()
            issue = .format
            if raw.utf8.count <= 180_000, let jsonSlice = extractJSONObject(from: raw),
                let decoded = try? JSONDecoder().decode(T.self, from: Data(jsonSlice.utf8)),
                let result = accept(decoded)
            {
                return result
            }
        }
        throw issue
    }

    static func extractJSONObject(from raw: String) -> Substring? {
        var source = raw[...]
        if let fenceStart = source.range(of: "```"),
            let lineEnd = source[fenceStart.upperBound...].firstIndex(of: "\n"),
            let fenceEnd = source[lineEnd...].range(of: "```")
        {
            source = source[source.index(after: lineEnd)..<fenceEnd.lowerBound]
        }
        guard let start = source.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < source.endIndex {
            let ch = source[index]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return source[start...index]
                    }
                }
            }
            index = source.index(after: index)
        }
        if let end = source.lastIndex(of: "}"), start <= end {
            return source[start...end]
        }
        return nil
    }
}
