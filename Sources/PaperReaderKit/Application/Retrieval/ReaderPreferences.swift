import Foundation

/// Only statements attributable to this reader can become active defaults. Older memories
/// decode without metadata and retain their original retrieval behavior.
public struct ReaderPreference: Codable, Sendable, Equatable {
    public enum Scope: Codable, Sendable, Equatable {
        case library
        case shelf(UUID)
        case paper(UUID)
    }
    public enum Aspect: String, Codable, Sendable {
        case language, detail, structure, terminology, workflow, background, other
    }

    public let scope: Scope
    public let aspect: Aspect
    /// Conditions such as “when comparing experiments” remain part of the user's own words.
    public let conditional: Bool

    public static func permitsRecall(_ text: String) -> Bool {
        !matches(
            text,
            #"(?i)(?:别|不要|不用|禁止|无需|忽略|跳过|关闭).{0,12}(?:使用|调用|用|参考|读取|检索)?(?:我的|个人|之前的|历史|长期)?(?:记忆|偏好|个人背景|历史对话)|(?:without|ignore|skip|disable|do not use|don't use).{0,18}(?:memor(?:y|ies)|preferences|personalization|past chats)"#
        )
    }

    private static let temporary =
        #"(?i)这次|本次|这回|本轮|只在本轮|这一轮|这一次|这一节|仅限|仅此|only (?:this|for)|just (?:this|for)|this time|for now|for this (?:one|answer|turn)"#

    public static func temporaryOverrides(in question: String) -> Set<Aspect> {
        guard matches(question, temporary) else { return [] }
        return Set(
            aspectPatterns.compactMap { aspect, pattern in
                [.language, .detail, .structure].contains(aspect) && matches(question, pattern) ? aspect : nil
            })
    }

    public static func permitsExtraction(_ text: String) -> Bool {
        ResearchMemory.permitsAutomaticWrite(for: text) && permitsRecall(text)
            && !matches(text, temporary)
            && !matches(text, #"(?i)api[ _-]?key|sk-[a-z0-9]{8}|bearer\s+|密码|私钥|密钥|password|secret key|access token"#)
    }

    /// Reserve the optional extraction request for an ongoing reader-owned project or question.
    public static func hasResearchSignal(in message: String) -> Bool {
        guard permitsExtraction(message),
            !ResearchQuestionProposal.isOperational(message),
            !ResearchQuestionProposal.isRecallRequest(message)
        else { return false }
        return ResearchQuestionProposal.isWriteRequest(message)
            || matches(
                message,
                #"(?i)(?:我|我们)(?:目前|接下来|一直|之后|最近|后续|长期|的)?(?:正在|在做|在研究|在追|打算|计划|会继续|想继续|想研究|想比较|想弄清|关心|关注|研究方向|项目|假设)|(?:my|our) (?:project|research|hypothesis|plan)|(?:i|we) (?:plan to|want to (?:study|investigate|follow up)|am studying|are studying|track|am working on|are working on)"#
            )
    }

    public static func isReview(_ text: String) -> Bool {
        matches(
            text,
            #"(?i)(?:记得|记住了|保存了|已存|记下了|查看|列出).{0,12}偏好[呢吗有哪些什么？?。.!！\s]*$|我有哪些(?:回答|交流|阅读)?偏好|what are my (?:response |reading )?preferences|what preferences (?:do|have) you|list my preferences"#
        )
    }

    public static func asksAboutLastUse(_ text: String) -> Bool {
        matches(
            text,
            #"(?i)(?:刚才|上次|本次|这次|刚刚).{0,10}(?:使用|用了|参考|用到|采用).{0,12}(?:偏好|记忆)|which (?:preferences|memories) did you (?:use|apply)"#
        )
    }

    public static func forgetTarget(_ text: String) -> String? {
        let pattern =
            #"(?i)^\s*(?:(?:请|帮我|麻烦你)\s*)?(?:忘掉|忘记|删除|移除|撤回|forget|remove|delete)\s*(?:我的?|my\s+)?(.{1,200}?)\s*[。.!！]?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        let target = String(text[range])
        guard matches(target, #"(?i)偏好|习惯|preference|habit"#) else { return nil }
        return target
    }

    /// Keep whole clauses. A quotation inside a paper, a question about the user, and a
    /// one-off instruction cannot supply personal defaults.
    public static func statement(in message: String) -> String? {
        guard permitsExtraction(message), !isReview(message), !asksAboutLastUse(message),
            forgetTarget(message) == nil, message.utf8.count <= 4000
        else { return nil }
        let value = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...240).contains(value.count),
            !matches(
                value,
                #"[?？「」『』“”`"<>]|(?i:例如|比如|举例|假设|假如|作者|说过|他说|她说|有人说|原文|举个例子|for example|suppose|imagine|the author|someone said|if I said)"#
            ),
            !ResearchQuestionProposal.isOperational(value), !ResearchQuestionProposal.isWriteRequest(value)
        else { return nil }
        let durable =
            #"(?i)^\s*(?:(?:请|请你|麻烦你|记住|请记住|请记下|please remember|remember that)[，,:：\s]*)?(?:(?:从今以后|以后|今后|往后|默认|从现在起)|我(?:平常|平时|通常|习惯|偏好|更喜欢|喜欢(?:用|先|从|把|看)|喜欢你|希望你以后|希望你每次|刚接触|已经熟悉|擅长|的母语是|更在意|最在意)|(?:in (?:this|my) (?:project|shelf)|for this paper|这个书架|在这个书架|这个项目|在这个项目|这篇论文里|读这篇论文时).{0,14}(?:默认|以后|我习惯|我希望|always|by default)|(?:i (?:generally |usually |always )?(?:prefer|like (?:you|my answers)|am new to)|i'm new to|from now on|by default|always (?:explain|answer|give|start|respond|include|use|write))\b)"#
        guard matches(value, durable),
            aspect(of: value) != .other
                || matches(
                    value,
                    #"(?i)我(?:习惯|偏好|更喜欢|喜欢(?:用|先|从|把|看)|喜欢你|希望你|刚接触|已经熟悉|擅长|的母语是|更在意|最在意)|(?:以后|默认|今后).{0,8}(?:叫我|称呼|回答|解释|请你|写作|交流|引用)|(?:i (?:prefer|like)|by default|from now on|always (?:respond|use))"#
                )
        else { return nil }
        // Do not swallow a separate task appended to a statement. The model can answer the combined turn.
        guard !matches(value, #"(?i)[。.!！；;\n]\s*\S|[，,]\s*(?:请帮|请问|请查|找一下|下载|解释一下|能否|could you|can you)"#)
        else { return nil }
        guard
            !ResearchQuestionProposal.isOperational(
                value.replacingOccurrences(
                    of: #"^(?:请)?(?:今后|以后|默认|往后|从今以后)\s*"#, with: "", options: .regularExpression))
        else { return nil }
        return value
    }

    /// A durable declaration may be followed by an unrelated question in the same turn.
    /// Only complete reader-authored sentences can cross the persistence boundary.
    public static func declaredClauses(in message: String) -> [String] {
        guard permitsExtraction(message), message.utf8.count <= 4000,
            !matches(message, #"[「」『』“”`"<>]|(?i:比如|例如|假设|原文|作者|转述|for example|someone said|the author)"#)
        else { return [] }
        let match = try! NSRegularExpression(pattern: #"[^。！？.!?；;\n]+[。！？.!?；;\n]?"#)
        return match.matches(in: message, range: NSRange(message.startIndex..., in: message)).compactMap { piece in
            guard let range = Range(piece.range, in: message) else { return nil }
            let sentence = String(message[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let last = sentence.last, !"?？".contains(last) else { return nil }
            return statement(in: sentence.trimmingCharacters(in: CharacterSet(charactersIn: "。.!！；;")))
        }
    }

    public static func classify(_ statement: String, paperID: UUID?, shelfID: UUID?) -> Self? {
        let scope: Scope
        if matches(statement, #"(?i)这篇论文|本篇|this paper"#) {
            guard let paperID else { return nil }
            scope = .paper(paperID)
        } else if matches(statement, #"(?i)这个书架|本书架|这个项目|本项目|this (?:project|shelf)"#) {
            guard let shelfID else { return nil }
            scope = .shelf(shelfID)
        } else {
            scope = .library
        }
        return Self(scope: scope, aspect: aspect(of: statement), conditional: hasCondition(statement))
    }

    private static func hasCondition(_ text: String) -> Bool {
        matches(text, #"(?i)每当|当.{0,24}时|如果|阅读.{0,10}时|看.{0,8}时|看实验|读实验|比较实验|讨论.{0,8}时|when |whenever |while |if "#)
    }

    func corrected(using text: String) -> Self {
        let revised = Self.aspect(of: text)
        return Self(scope: scope, aspect: revised == .other ? aspect : revised, conditional: Self.hasCondition(text))
    }

    private static let aspectPatterns: [(Aspect, String)] = [
        (
            .language,
            #"(?i)(?:以|用|使用|默认|改成|换成|改用|给)(?:中文|英文|英语|日语|法语)|(?:answer|respond|write|explain) in (?:english|chinese|japanese|french)"#
        ),
        (.detail, #"(?i)一句话|简短|简洁|短回答|简明|详细|详尽|one sentence|多些细节|少些细节|brief|concise|short answers|more detail"#),
        (.structure, #"(?i)先讲|先说|先给|先看|先问|先告诉|结论先|先列|先用|lead with|start with|first|bullets"#),
        (.terminology, #"(?i)术语|terminology|terms"#),
        (.workflow, #"(?i)实验|数据|对照|分母|预算|experiment|budget|baseline"#),
        (.background, #"(?i)刚接触|已经熟悉|擅长|的母语是|new to|familiar with"#),
    ]

    public static func aspect(of value: String) -> Aspect {
        aspectPatterns.first { matches(value, $0.1) }?.0 ?? .other
    }

    /// A compound declaration may establish independent defaults. Split only a fully recognized
    /// list of distinct aspects and leave conditional phrasing intact.
    public func components(of statement: String) -> [(ReaderPreference, String)] {
        let parts = statement.components(separatedBy: CharacterSet(charactersIn: "，,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !conditional, parts.count > 1 else { return [(self, statement)] }
        let aspects = parts.map(Self.aspect(of:))
        guard !aspects.contains(.other), Set(aspects).count == parts.count else { return [(self, statement)] }
        return zip(aspects, parts).map { (Self(scope: scope, aspect: $0, conditional: false), $1) }
    }

    public static func sameStatement(_ lhs: String, _ rhs: String) -> Bool {
        let punctuation = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "。.!！；;"))
        return lhs.trimmingCharacters(in: punctuation).localizedCaseInsensitiveCompare(
            rhs.trimmingCharacters(in: punctuation)) == .orderedSame
    }

    public static func conditionMatches(_ preference: String, query: String) -> Bool {
        // These named contexts cover common deictic questions such as “表三呢?”; other
        // conditions use the actual terms the reader supplied.
        for (condition, activation) in [
            (
                "实验|对照|评测|experiment|baseline",
                "实验|表(?:格|[一二三四五六七八九十0-9]+)|这张表|该表|对照|结果|基线|指标|experiment|table|baseline|result"
            ),
            ("公式|推导|equation|derivation", "公式|推导|证明|方程|equation|formula|derive|proof"),
            ("推荐|找文献|recommend", "推荐|找文献|找论文|recommend|find papers"),
        ] where matches(preference, "(?i)" + condition) {
            return matches(query, "(?i)" + activation)
        }
        let stop: Set<String> = ["以后", "我", "你", "时", "当", "如果", "先", "的", "the", "when", "i", "a", "if", "for"]
        return !Retriever.tokens(preference).subtracting(stop).isDisjoint(
            with: Retriever.tokens(query).subtracting(stop))
    }

    public func applies(paperID: UUID?, shelfID: UUID?) -> Bool {
        switch scope {
        case .library: true
        case .shelf(let id): id == shelfID
        case .paper(let id): id == paperID
        }
    }

    public static func active(in state: LibraryState, paperID: UUID?, shelfID: UUID?, excluding pending: Set<UUID> = [])
        -> [MemoryItem]
    {
        let candidates = state.memories.filter {
            $0.preference?.applies(paperID: paperID, shelfID: shelfID) == true && !$0.deleted && !$0.text.isEmpty
        }
        let origins = ResearchMemoryOrigins(state: state, excluding: pending, for: candidates)
        return candidates.filter { origins.resolve($0) != nil }.sorted {
            func priority(_ item: MemoryItem) -> Int {
                switch item.preference?.scope {
                case .paper: 2
                case .shelf: 1
                default: 0
                }
            }
            if priority($0) != priority($1) { return priority($0) > priority($1) }
            return $0.createdAt > $1.createdAt
        }
    }

    public static func matchingForget(_ target: String, in items: [MemoryItem]) -> [MemoryItem] {
        let cleaned = target.replacingOccurrences(
            of: #"(?i)偏好|习惯|preference\s*(?:for|of|to)?|habit\s*(?:of)?"#, with: "", options: .regularExpression
        )
        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:「」“”\"的")))
        let exact = items.filter { !cleaned.isEmpty && $0.text.localizedCaseInsensitiveContains(cleaned) }
        if !exact.isEmpty { return exact }
        // Do not delete a different language or the opposite verbosity just because the category matches.
        let equivalents = ["简短|简洁|短回答|精简|brief|concise|short answer", "详细|详尽|more detail|in depth"]
        for pattern in equivalents where matches(cleaned, "(?i)" + pattern) {
            return items.filter { matches($0.text, "(?i)" + pattern) }
        }
        return []
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

/// A compare-and-swap over only the records touched by one reader command.
public struct ReaderPreferenceChange: Sendable {
    public let previous: [MemoryItem]
    public let insertions: [MemoryItem]
    public var originatingTurn: ChatTurn?
    public var linkExistingTurn = false

    public init(previous: [MemoryItem], insertions: [MemoryItem] = [], originatingTurn: ChatTurn? = nil) {
        self.previous = previous
        self.insertions = insertions
        self.originatingTurn = originatingTurn
    }

    public func apply(to state: inout LibraryState) -> Bool {
        guard previous.allSatisfy({ state.memories.contains($0) }) else { return false }
        for item in insertions {
            guard let preference = item.preference else { return false }
            switch preference.scope {
            case .library: break
            case .paper(let id): guard state.papers.contains(where: { $0.id == id }) else { return false }
            case .shelf(let id): guard state.shelves.contains(where: { $0.id == id }) else { return false }
            }
            if preference.replacesSameAspect {
                let competing = state.memories.filter { !$0.deleted && $0.preference == preference }
                guard Set(competing.map(\.id)) == Set(previous.filter { $0.preference == preference }.map(\.id)) else {
                    return false
                }
            }
            guard
                !state.memories.contains(where: {
                    $0.id == item.id
                        || (!$0.deleted && $0.preference == preference
                            && ReaderPreference.sameStatement($0.text, item.text))
                })
            else { return false }
        }
        if linkExistingTurn {
            guard insertions.allSatisfy({ item in state.chats.contains { $0.id == item.sourceID } }) else {
                return false
            }
        } else if let turn = originatingTurn {
            // The originating turn is appended below, so chat-sourced memories may point at it.
            guard insertions.allSatisfy({ $0.librarySource != nil || $0.sourceID == turn.id }) else {
                return false
            }
        } else {
            // A reader-preference memory without a library source must resolve to a real turn.
            guard
                insertions.allSatisfy({ item in
                    item.librarySource != nil || state.chats.contains { $0.id == item.sourceID }
                })
            else { return false }
        }
        if let turn = originatingTurn {
            guard state.papers.contains(where: { $0.id == turn.paperID }),
                !state.chats.contains(where: { $0.id == turn.id })
            else { return false }
        }
        let removed = Set(previous.map(\.id))
        for index in state.memories.indices where removed.contains(state.memories[index].id) {
            state.memories[index].forget()
        }
        for insert in insertions {
            state.memories.append(insert)
            if linkExistingTurn, let index = state.chats.firstIndex(where: { $0.id == insert.sourceID }) {
                state.chats[index].backgroundSources?.include(insert)
            }
        }
        if let originatingTurn { state.chats.append(originatingTurn) }
        return true
    }
}

extension ReaderPreference {
    public var replacesSameAspect: Bool {
        !conditional && [.language, .detail].contains(aspect)
    }
}
