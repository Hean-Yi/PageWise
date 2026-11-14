import Foundation
import JavaScriptCore
import SwiftSoup

/// Import-time compilation to native MathML. No TeX process, browser script or remote service.
final class LatexMathCompiler {
    private let context: JSContext
    init() throws {
        guard let context = JSContext(),
            let url = Bundle.module.url(forResource: "katex.min", withExtension: "js", subdirectory: "KaTeX")
        else { throw ReaderError.message("本地公式编译器无法加载，已保留原版。") }
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        guard context.exception == nil, context.objectForKeyedSubscript("katex")?.isObject == true else {
            throw ReaderError.message("本地公式编译器初始化失败，已保留原版。")
        }
        self.context = context
    }

    func compile(_ latex: String, display: Bool) throws -> String {
        guard !latex.isEmpty, latex.utf8.count <= 16_000,
            latex.range(of: #"\\(?:href|url|includegraphics|html\w*)\b"#, options: .regularExpression) == nil
        else { throw ReaderError.message("公式超出本地编译范围，已保留原版。") }
        context.exception = nil
        let options: [String: Any] = [
            "displayMode": display, "output": "mathml", "throwOnError": true,
            "strict": "error", "trust": false, "maxExpand": 1_000, "maxSize": 20,
        ]
        let result = context.objectForKeyedSubscript("katex")?.invokeMethod(
            "renderToString", withArguments: [latex, options])
        guard context.exception == nil, let markup = result?.toString(),
            let math = try SwiftSoup.parseBodyFragment(markup).select("math").first(),
            !markup.contains("#cc0000")
        else { throw ReaderError.message("LaTeX 公式无法可靠编译，未发布错误公式；请查看原版。") }
        try math.select("annotation,annotation-xml").remove()
        try math.attr("alttext", latex)
        return try math.outerHtml()
    }
}
