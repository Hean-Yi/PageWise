import Foundation

public enum AgentLibraryScope: String, CaseIterable, Sendable {
    case shelves, papers, shelf, unfiled
}

public enum AgentLibraryOperation: Sendable, Equatable {
    case list(AgentLibraryScope, shelf: UUID?, offset: Int)
    case prepareLocalImport(UUID?)
    case createShelf(String)
    case renameShelf(UUID, String)
    case movePapers([UUID], to: UUID?)
    case prepareDeleteShelf(UUID)
    case prepareDeletePaper(UUID)
}

/// Only the reader's directive may enable writes. Titles, quoted examples, excerpts and model replies grant none.
public enum LibraryOrganizationIntent {
    public static func tools(for question: String) -> Set<String> {
        let text = question.lowercased().replacingOccurrences(
            of: #"(?s)`{3}.*?(?:`{3}|$)|“[^”]*”|「[^」]*」|『[^』]*』|《[^》]*》|"[^"]*"|‘[^’]*’|`[^`]*`"#,
            with: "…", options: .regularExpression)
        if text.range(
            of:
                #"假如|如果|假设|举例|先.{0,10}(?:方案|建议)|只(?:需|要|给我)?(?:给.{0,4})?(?:建议|方案|预览)|what if|hypothetical|preview only"#,
            options: .regularExpression
        ) != nil {
            return []
        }
        let clauses = text.components(separatedBy: CharacterSet(charactersIn: "，。；,;!！\n"))
        var permitted = Set<String>()
        var withheld = Set<String>()
        for clause in clauses {
            if let negative = clause.range(
                of: #"不要|不用|不必|无需|暂不|别(?=动|改|删|建|放|整理)|do not |don['’]t "#, options: .regularExpression)
            {
                let restriction = String(clause[negative.upperBound...]).trimmingCharacters(in: .whitespaces)
                withheld.formUnion(tools(inClause: restriction))
                if restriction.range(
                    of: #"^(?:动|修改|更改|改动|调整)(?:我的|现有|任何|整个)?(?:书库|馆藏|书架)"#, options: .regularExpression) != nil
                {
                    return []
                }
            } else {
                permitted.formUnion(tools(inClause: clause))
            }
        }
        return permitted.subtracting(withheld)
    }

    private static func tools(inClause text: String) -> Set<String> {
        func has(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        if has(
            #"不要|不用|不必|无需|暂不|别(?:动|改|删|建|放|整理)|仅供参考|如何|怎么|为什么|只(?:需|要)?(?:建议|分析|预览|讨论|列出)|先.{0,4}(?:方案|建议)|(?:do not|don['’]t|suggest|hypothetical|how (?:can|do|would)|what if|preview only)\b"#
        ) {
            return []
        }
        let command =
            #"(?:(?:^|[，。；,;!！\n]|并且|然后|顺便|以及|并|再|please | and | then )\s*(?:(?:请你?|帮我|麻烦你?|替我|给我|现在|直接|先|我想(?:请你)?|我希望你|你能不能|能不能|可以|can you |could you |please )\s*)*)"#
        func directs(_ expression: String) -> Bool { has(command + "(?:" + expression + ")") }
        var names = Set<String>()
        if directs(
            #"(?:整理|归类|分类|分组|划分).{0,60}(?:书库|论文|书架|文献)|(?:把|将).{1,80}(?:按.{1,16})?(?:归类|分类|分组|整理)|(?:把|将).{0,90}按.{1,20}(?:归到|归入|放到|分到).{0,30}书架|(?:organize|organise|categorize|categorise|classify|group|sort)\b"#
        ) {
            names.formUnion(["create_shelf", "move_papers"])
        }
        if directs(#"(?:新建|创建|建立|增加|添加|建).{0,60}(?:书架|分类)|(?:create|add|make)\b.{0,80}\bshel(?:f|ves)\b"#) {
            names.insert("create_shelf")
        }
        if directs(#"(?:重命名|改名|更名)|(?:把|将|给).{0,80}(?:重命名|改名|改成|改为|更名)|rename\b"#) {
            names.insert("rename_shelf")
        }
        if directs(
            #"(?:移动|移到|移入|移出|归入|放到|放入|加入|分到)|(?:把|将|从).{0,180}(?:移到|移动|移入|移出|移回|放到|放入|放进|挪到|归入|分到|收进|加入|拿出)|(?:move|file|unfile|assign|put)\b|remove\b.{0,80}\bfrom\b.{0,50}\bshelf\b"#
        ) {
            names.insert("move_papers")
        }
        let fromShelf = has(
            #"从.{0,70}(?:书架|分类|分组).{0,40}(?:移除|删除|移出|拿出|移走)|\bremove\b.{1,100}\bfrom\b.{0,80}\bshelf\b"#)
        if fromShelf {
            if directs(#"(?:把|将|从|remove\b)"#) { names.insert("move_papers") }
        } else if directs(
            #"(?:(?:永久|彻底)?删除|移除|丢弃|扔掉|删掉|删去|删)|(?:将|把|从).{0,180}(?:删除|删掉|移除|丢弃)|(?:permanently )?(?:delete|remove)\b"#)
        {
            let mentionsShelf = has(#"书架|\bshel(?:f|ves)\b"#)
            let mentionsPaper = has(#"论文|文章|这篇|那篇|\b(?:paper|article)s?\b"#)
            if mentionsPaper || !mentionsShelf { names.insert("prepare_delete_paper") }
            if mentionsShelf || !mentionsPaper { names.insert("prepare_delete_shelf") }
        }
        if directs(
            #"(?:导入|添加|加入|上传|选取).{0,80}(?:本地|pdf|文件)|(?:把|将|从).{0,180}(?:本地|pdf|文件).{0,80}(?:添加|导入|加入|放入)|(?:import|add)\b.{0,80}\b(?:file|local|pdf)s?\b"#
        ) {
            names.insert("prepare_local_import")
        }
        return names
    }
}
