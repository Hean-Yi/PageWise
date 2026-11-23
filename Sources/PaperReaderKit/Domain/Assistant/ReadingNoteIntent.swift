import Foundation

/// Tool permission comes from the reader's current message. Quoted material is data, including quoted commands.
public enum ReadingNoteIntent {
    private static let quotation = try! NSRegularExpression(
        pattern: #"“([^”]+)”|「([^」]+)」|『([^』]+)』|‘([^’]+)’|"([^"]+)"|\x60([^\x60]+)\x60"#)
    private static let marking =
        #"(?:标出|标记|标注|标画|圈出|高亮|画线|划线|画出|引用(?:本篇|当前论文|本文)?原文|highlight|underline|mark|quote\s+(?:the\s+)?(?:source|passage))"#

    public static func isRequested(_ question: String) -> Bool {
        let withoutCode = question.replacingOccurrences(
            of: #"(?s)\x60{3}.*?(?:\x60{3}|$)"#, with: "…", options: .regularExpression)
        let text = quotation.stringByReplacingMatches(
            in: withoutCode, range: NSRange(withoutCode.startIndex..., in: withoutCode), withTemplate: "…"
        )
        .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Treat the text after a colon as note content, after recognizing the command in front.
        let command = String(text.prefix { $0 != "：" && $0 != ":" })
        guard !command.isEmpty, command.count <= 4_000,
            !contains(
                #"(?:不要|不用|不必|无需|不需要|暂不|别|不想)(?:(?:把|将|在).{0,50}?)?(?:再|实际|直接|自动|给我|帮我|真的|现在|先|\s)*(?:写|记|做|存|保|落盘|标|高亮|下划线)|只(?:需|要)?(?:草拟|预览|展示|讨论)|先(?:让我确认|给我看|问我|给我预览)|等我确认|待我确认|不落盘|\b(?:don['’]t|do not|never|without)\s+(?:(?:actually|automatically)\s+)?(?:writ|sav|creat|add|record|highlight|mak|tak)|\bdraft only\b"#,
                in: command),
            !contains(
                #"^(?:如果|假如|假设|比如|例如|举个例子|示例|原文(?:写|说)|(?:他|她|作者|老师)(?:说|建议|要求)|suppose\b|if\b|for example\b)"#,
                in: command)
        else { return false }
        if contains(#"(?:需要多久|要多久|需要什么|会怎样|会怎么样|是什么意思)\s*[?？。]*$"#, in: command) { return false }
        let directQuestion = contains(
            #"^(?:请问)?(?:你)?(?:可以|可否|能否|能不能|能|可不可以)(?:请你|麻烦你)?(?:帮我|替我|给我)|^(?:can|could|would) you (?:please )?(?:save|write|attach|highlight|mark|add|record|make)\b"#,
            in: command)
        if contains(#"[?？吗]\s*[?？。!！]*$"#, in: command), !directQuestion { return false }
        let clauses = command.components(separatedBy: CharacterSet(charactersIn: "，,。；;!\n"))
        // The first clause may describe the mark while the next supplies its note.
        let joined = clauses.joined()
        if isDirective(joined) { return true }
        return clauses.dropFirst().contains { clause in
            let part = clause.trimmingCharacters(in: .whitespaces)
            return contains(#"^(?:请|帮我|替我|麻烦|然后请|please )"#, in: part) && isDirective(part)
        }
    }

    private static func isDirective(_ text: String) -> Bool {
        let prefix =
            #"^(?:(?:请问|请你|请|麻烦你|麻烦|我希望你|我需要你|我想让你|我想请你|我要你|我想|你|可不可以|可以|可否|能不能|能否|能|帮我|替我|给我|直接|现在|顺便|再|先|也|然后|\s))*"#
        let command = text.replacingOccurrences(of: prefix, with: "", options: .regularExpression)
        guard !contains(#"^(?:解释|介绍|谈谈|讲讲|告诉我|分析|示范|举例|比较|评价|翻译|复述|检查|模拟|怎么|如何|为什么)"#, in: command)
        else { return false }
        let target = #"(?:阅读|论文|本地)?笔记(?:里|中)?(?=$|[，,、。.!！；;：:\s吗？?]|并|然后|同时|标|贴|附|在)"#
        let writeNote =
            #"(?:写|做|作|记|存|保存|记录|整理|添加|新建|创建|生成|归入)(?:为|成|入|到|下|进|一条|一个|一则|一份|一篇|一下|个|条|上|一|我的|在原文旁|\s)*"# + target
        if contains(#"^(?:写|保存|生成|整理|添加|创建)(?:一篇|一份|一条|个)?(?:全文|全篇|整篇论文|论文)(?:总结|综述|总结性)(?:的)?笔记"#, in: command) {
            return true
        }
        if contains(#"^(?:把|将)(?:全文|全篇|整篇论文|这篇论文)(?:总结|概括|整理)成(?:一份|一篇|一条)?(?:总结|阅读)?笔记"#, in: command) { return true }
        if contains(#"^(?:总结|概括|梳理)(?:这篇|整篇|全篇|全文|本篇|该论文|这篇论文|本文)"#, in: command),
            contains(writeNote, in: command)
        {
            return true
        }
        if contains("^" + writeNote, in: command) { return true }
        if contains(#"^(?:把|将|给|为|在|对|针对|高亮|标画|标注|标出|划线|画线)"#, in: command) {
            if contains(writeNote, in: command) { return true }
            let putAtSource = #"(?:记|记录|保存|写)(?:下(?:来)?|起来|到|在|入)(?:论文|对应|原文|正文|的|中|旁|位置|边上|这里|这段)*"#
            if contains(putAtSource, in: command) { return true }
            if contains(marking, in: command),
                contains(#"(?:写下|留下|附上|记上)(?:我们|刚才|之前|这些|这个|一段|我的|的)*(?:看法|观点|结论|分析|想法|评论|解释)"#, in: command)
            {
                return true
            }
        }
        if contains(#"^(?:记下(?:来|这个|这条|我们|刚才|这段|上面)|记下来|记录下(?:这|刚才|我们))"#, in: command) { return true }
        let english = command.replacingOccurrences(
            of: #"^(?:(?:can|could|would) you )?(?:please )?"#, with: "", options: .regularExpression)
        return contains(
            #"^(?:add|attach|make|write|save|create|take|record)\s+(?:(?:a|an|the|this|these|our|my|me|reading|paper|summary|local|as|to|into|discussion|conclusion|point|in)\s+)*notes?\b|^note (?:this|that) down\b"#,
            in: english)
    }

    /// The text quoted for the note cannot choose its destination.
    public static func requestsDocumentSummary(_ instruction: String) -> Bool {
        guard isRequested(instruction) else { return false }
        let plain = quotation.stringByReplacingMatches(
            in: instruction, range: NSRange(instruction.startIndex..., in: instruction), withTemplate: "…")
        let command = String(plain.prefix { $0 != "：" && $0 != ":" }).lowercased()
        return contains(
            #"(?:全文|全篇|整篇(?:论文|文章)?|(?:这篇|本篇|该|本)论文|这篇文章|本文|论文)(?:的|做个|做一份|做一个|写一份|写一个|进行|写成|整理成)?(?:整体|总体)?(?:总结|综述|概览)|(?:总结|概括|综述|梳理)(?:一下)?(?:全文|全篇|整篇|(?:这篇|本篇|该)论文|本文)|(?:放|记|写|保存)(?:在|到)(?:全文结尾|文末)(?:的)?(?:总结|笔记)|\b(?:summary (?:note )?(?:of|for) (?:the|this|the entire|the whole) paper|paper summary note)\b"#,
            in: command)
    }

    /// Only quoted passages governed by an explicit markup verb constrain the final source locations.
    public static func requestedQuotations(in instruction: String) -> [String] {
        let matches = quotation.matches(in: instruction, range: NSRange(instruction.startIndex..., in: instruction))
        let string = instruction as NSString
        var passages: [String] = []
        var selected: [Bool] = []
        var gaps: [String] = []
        var end = 0
        for match in matches {
            gaps.append(string.substring(with: NSRange(location: end, length: match.range.location - end)))
            end = NSMaxRange(match.range)
            passages.append(
                string.substring(with: NSRange(location: match.range.location + 1, length: match.range.length - 2)))
        }
        gaps.append(string.substring(from: end))
        let separators = CharacterSet(charactersIn: "，,。；;！!？?\n")
        let noteBody =
            #"(?:观点是|我的看法是|笔记(?:里|正文|内容)?(?:写|是|为)|(?:做|写|记|添加|整理)(?:一条|个|篇|份|阅读)?笔记|写(?:下|上)|标题(?:用|为)|note (?:says|reads)|write in the note)"#
        for i in passages.indices {
            let before = (gaps[i].components(separatedBy: separators).last ?? "").lowercased()
            let after = (gaps[i + 1].components(separatedBy: separators).first ?? "").lowercased()
            let beforeMark = before.range(of: marking, options: [.regularExpression, .backwards])
            let markBefore = beforeMark.map { !contains(noteBody, in: String(before[$0.upperBound...])) } ?? false
            let markAfter = contains(
                #"^\s*(?:这(?:一|两)?(?:句|处|段)(?:原文)?|这一部分|原文|部分|\s)*(?:用.{0,3}色)?"# + marking, in: after)
            selected.append(markBefore || markAfter)
        }
        // A comma or conjunction can join several quotes to one markup verb on either side.
        for i in passages.indices where selected[i] {
            var j = i
            while j > 0, isListSeparator(gaps[j]) {
                j -= 1
                selected[j] = true
            }
            j = i
            while j + 1 < passages.count, isListSeparator(gaps[j + 1]) {
                j += 1
                selected[j] = true
            }
        }
        var seen = Set<String>()
        return zip(passages, selected).compactMap { text, chosen in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return chosen && !trimmed.isEmpty && seen.insert(trimmed).inserted ? trimmed : nil
        }
    }

    private static func isListSeparator(_ text: String) -> Bool {
        contains(#"^(?:[\s，,、]|以及|和|与|及|and)*$"#, in: text.lowercased())
    }

    private static func contains(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
