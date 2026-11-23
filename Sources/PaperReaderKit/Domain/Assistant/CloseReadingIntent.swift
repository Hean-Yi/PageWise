import Foundation

public enum CloseReadingIntent {
    public static func isRequested(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // A constraint on the analysis ("不要默认作者正确") still leaves the reading request intact.
        let negation = #"(?:不要|不用|不必|无需|不需要|不想|不|别|勿)(?:先|再|直接|自动|给我|帮我|替我|为我|另外|开启|启动|进行|做一次|做|\s)*(?:ai\s*)?"#
        let operation = #"(?:精读|保存|写入|落盘|(?:写|记|做|生成|添加|保留)?(?:任何|新的|一条|一份|一个|阅读|精读|\s)*笔记|标注|标画|高亮|划线)"#
        let readOnly =
            #"只(?:需|要)?(?:讨论|解释|预览)|\b(?:do not|don['’]t|never|without)\s+(?:actually\s+)?(?:close[- ]read|sav|writ|annotat|highlight|making notes|taking notes)"#
        guard text.range(of: negation + operation, options: .regularExpression) == nil,
            text.range(of: readOnly, options: .regularExpression) == nil
        else { return false }

        let featureQuestion = #"^(?:请问\s*)?(?:ai\s*)?精读(?:功能)?[\s，,]*(?:什么意思|是什么|如何|怎么|要多久|需要多久|能|可以|是否|支持|会不会|有什么)"#
        guard text.range(of: featureQuestion, options: .regularExpression) == nil else { return false }
        let first = text.prefix { !"，,。；;：:\n".contains($0) }
        let asksAboutFeature = #"什么意思|是什么|如何使用|怎么用|如何精读|怎么精读|需要多久|能做什么"#
        guard first.range(of: asksAboutFeature, options: .regularExpression) == nil else { return false }
        let politeRequest = #"^(?:你)?(?:可以|可不可以|能不能|能否|可否)\s*(?:请你|麻烦你)?(?:替我|给我|帮我)"#
        if first.range(of: #"[吗?？]\s*[?？!！]*$"#, options: .regularExpression) != nil,
            first.range(of: politeRequest, options: .regularExpression) == nil
        {
            return false
        }
        let directive =
            #"^(?:(?:请你|请|帮我|麻烦你|可以帮我|能否帮我|我想请你|我想让你|我想|希望你|现在|开始|进行|启动|运行|使用|用|对这篇论文进行|给我|为我|\s))*(?:ai\s*)?精读(?:$|一下|全文|本|此|这|那|吗|论文|《|\s|[，。！：,:])|^(?:please )?(?:run (?:an? )?|start (?:an? )?)?(?:ai )?close[- ]read(?:ing)?(?:$|\s)"#
        let command = text.replacingOccurrences(of: politeRequest, with: "", options: .regularExpression)
        return command.range(of: directive, options: .regularExpression) != nil
    }
}
