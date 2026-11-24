import Foundation
import JavaScriptCore
import SwiftSoup

/// Local-only rendering. User source is never evaluated as JavaScript or sent to a server.
public actor NoteMarkdownRenderer {
    private var engine: JSContext?
    private var mathCompiler: LatexMathCompiler?
    public init() {}
    public func render(_ markdown: String) throws -> String {
        try markdownDocument(markdown).body()?.html() ?? ""
    }

    /// The reader may activate only a passage registered on this particular note.
    public func renderReadingNote(_ markdown: String, passageIDs: Set<UUID>, trackSourceRanges: Bool = false) throws
        -> String
    {
        try markdownDocument(markdown, passageIDs: passageIDs, trackSourceRanges: trackSourceRanges).body()?.html()
            ?? ""
    }

    func markdownDocument(_ markdown: String, passageIDs: Set<UUID>? = nil, trackSourceRanges: Bool = false) throws
        -> Document
    {
        if engine == nil {
            guard let context = JSContext(),
                let url = Bundle.module.url(forResource: "marked.umd", withExtension: "js", subdirectory: "Marked")
            else { throw ReaderError.message("本地 Markdown 组件不可用，源码已保留。") }
            context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
            context.evaluateScript(Self.extensions)
            engine = context
        }
        guard let context = engine else { throw ReaderError.message("Markdown 预览不可用，源码已保留。") }
        // Only ranges emitted by our parser survive sanitization, even when a note contains raw HTML.
        let sourceAttribute = trackSourceRanges ? "data-pr-" + UUID().uuidString.lowercased() : nil
        context.setObject(sourceAttribute ?? "", forKeyedSubscript: "noteBlockAttribute" as NSString)
        context.evaluateScript("noteMath=[]")
        context.exception = nil
        guard
            let html = context.objectForKeyedSubscript("marked")?.invokeMethod("parse", withArguments: [markdown])?
                .toString(),
            context.exception == nil
        else { throw ReaderError.message("笔记预览暂不可用，源码已保留。") }
        let math = context.objectForKeyedSubscript("noteMath")?.toArray() as? [[String: Any]] ?? []
        let document = try SwiftSoup.parseBodyFragment(html)
        // Allow semantic Markdown only. No raw styles, scripts, embedded frames or remote resources.
        try document.select("script,style,iframe,object,embed,svg,math,link,meta,form,textarea").remove()
        let allowed: Set<String> = [
            "p", "br", "hr", "h1", "h2", "h3", "h4", "h5", "h6", "strong", "em", "del", "blockquote", "ul", "ol", "li",
            "pre", "code", "table", "thead", "tbody", "tr", "th", "td", "a", "span", "input",
        ]
        for element in try document.body()?.select("*").array() ?? [] {
            if element.tagName() == "body" { continue }
            if !allowed.contains(element.tagName()) {
                try element.unwrap()
                continue
            }
            let blockRange = try sourceAttribute.flatMap { element.hasAttr($0) ? try element.attr($0) : nil }
            for attribute in element.getAttributes()?.asList() ?? [] {
                let key = attribute.getKey()
                let permitted =
                    (element.tagName() == "a" && key == "href")
                    || (element.tagName() == "span" && key == "data-note-math")
                    || (element.tagName() == "input" && ["type", "checked", "disabled"].contains(key))
                    || (element.tagName() == "ol" && key == "start")
                if !permitted { try element.removeAttr(key) }
            }
            if let blockRange { try element.attr("data-note-range", blockRange) }
            if element.tagName() == "input" {
                guard try element.attr("type") == "checkbox" else {
                    try element.remove()
                    continue
                }
                try element.attr("disabled", "")
            }
            if element.tagName() == "a" {
                let href = try element.attr("href")
                if let passageIDs {
                    if let url = URL(string: href), let id = LocalPassageCitation.id(from: url),
                        passageIDs.contains(id)
                    {
                        try element.attr("data-passage", id.uuidString)
                    } else {
                        try element.unwrap()
                    }
                } else if let url = URL(string: href), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                    url.host != nil
                {
                    try element.attr("rel", "noreferrer noopener")
                } else {
                    try element.removeAttr("href")
                }
            }
        }

        for element in try document.select("span[data-note-math]") {
            guard let index = Int(try element.attr("data-note-math")), math.indices.contains(index),
                let source = math[index]["text"] as? String
            else {
                try element.removeAttr("data-note-math")
                continue
            }
            do {
                if mathCompiler == nil { mathCompiler = try LatexMathCompiler() }
                let rendered = try mathCompiler!.compile(source, display: math[index]["display"] as? Bool == true)
                try element.html(rendered)
                try element.attr("class", "note-math")
            } catch {
                try element.text(math[index]["raw"] as? String ?? source)
                try element.attr("class", "note-math-error")
                try element.attr("title", "公式暂无法编译，源码已保留")
            }
            try element.removeAttr("data-note-math")
        }
        return document
    }

    private static let extensions = #"""
        var noteMath=[];
        function recordMath(t) {
          const i=noteMath.push({text:t.text,raw:t.raw.trimEnd(),display:!!t.display})-1;
          return '<span data-note-math="'+i+'"></span>';
        }
        var noteBlockAttribute='';
        marked.use({hooks:{processAllTokens(tokens){
          if(!noteBlockAttribute)return tokens;
          let offset=0;
          return tokens.map(token=>{
            const start=offset;offset+=token.raw.length;
            if(token.type==='space'||token.type==='def')return token;
            return {type:'noteSourceBlock',token,start,end:offset};
          });
        }},extensions:[
          {name:'noteSourceBlock',level:'block',renderer({token,start,end}){
            const html=this.parser.parse([token]);
            return html.replace(/^\s*<[a-z][\w-]*(?=[\s>])/i,tag=>tag+' '+noteBlockAttribute+'="'+start+':'+end+'"');
          }},
          {name:'noteBlockMath',level:'block',start(src){return src.search(/(?:\$\$|\\\[)/);},
           tokenizer(src){const m=/^\$\$\s*([\s\S]+?)\$\$[ \t]*(?:\n|$)/.exec(src)||/^\\\[\s*([\s\S]+?)\\\][ \t]*(?:\n|$)/.exec(src);
             if(m)return {type:'noteBlockMath',raw:m[0],text:m[1],display:true};},
           renderer(t){return '<p>'+recordMath(t)+'</p>';}},
          {name:'noteInlineMath',level:'inline',start(src){return src.search(/(?:\$|\\[\[(])/);},
           tokenizer(src){
             const display=/^\$\$([\s\S]+?)\$\$/.exec(src)||/^\\\[([\s\S]+?)\\\]/.exec(src);
             const m=display||/^\\\(([\s\S]+?)\\\)/.exec(src)||/^\$(?![\s$])((?:\\.|[^$\n])+?)(?<!\s)\$(?![\d$])/.exec(src);
             if(m)return {type:'noteInlineMath',raw:m[0],text:m[1],display:!!display};},
           renderer:recordMath}
        ]});
        """#
}
