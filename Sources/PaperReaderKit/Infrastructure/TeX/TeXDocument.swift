import Foundation

struct TeXCursor {
    let characters: [Character]
    var index = 0
    init(_ text: String) { characters = Array(text) }
    var ended: Bool { index >= characters.count }
    var peek: Character? { ended ? nil : characters[index] }
    mutating func skipSpace() { while peek?.isWhitespace == true { index += 1 } }
    mutating func command() -> String {
        guard peek == "\\" else { return "" }
        index += 1
        let start = index
        while let c = peek, c.isLetter || c == "@" { index += 1 }
        if index == start, !ended { index += 1 }
        let result = String(characters[start..<index])
        if result.first?.isLetter == true {
            // TeX consumes spaces after a control word, but not a paragraph break.
            while peek == " " || peek == "\t" { index += 1 }
        }
        return result
    }
    mutating func group(open: Character = "{", close: Character = "}") throws -> String {
        skipSpace()
        guard peek == open else { throw TeXArchive.failure("缺少命令参数") }
        index += 1
        let start = index
        var depth = 1
        while !ended {
            if peek == "\\" {
                index += 1
                if !ended { index += 1 }
                continue
            }
            if peek == open { depth += 1 }
            if peek == close { depth -= 1 }
            if depth == 0 {
                let result = String(characters[start..<index])
                index += 1
                return result
            }
            index += 1
        }
        throw TeXArchive.failure("源码括号不完整")
    }
    mutating func optional() throws -> String? {
        skipSpace()
        return peek == "[" ? try group(open: "[", close: "]") : nil
    }
    mutating func until(_ delimiter: String) throws -> String {
        let remaining = String(characters[index...])
        guard let range = remaining.range(of: delimiter) else { throw TeXArchive.failure("源码环境未闭合") }
        let value = String(remaining[..<range.lowerBound])
        index += value.count + delimiter.count
        return value
    }
    mutating func literalEnvironment() throws -> String? {
        let saved = index
        guard command() == "begin", let name = try? group(), ["verbatim", "lstlisting"].contains(name) else {
            index = saved
            return nil
        }
        do { _ = try until("\\end{" + name + "}") } catch {
            index = saved
            throw error
        }
        return String(characters[saved..<index])
    }
}

struct TeXDocument {
    let files: [String: Data]
    let mainFile: String
    var macros: [String: Macro] = [:]
    var expandedCharacters = 0
    struct Macro {
        var arguments: Int
        var defaultArgument: String?
        var body: String
    }

    init(files: [String: Data]) throws {
        self.files = files
        let roots = files.keys.filter { path in
            guard path.lowercased().hasSuffix(".tex"), let data = files[path], data.count <= 8_000_000,
                let text = String(data: data, encoding: .utf8)
            else { return false }
            return Self.withoutComments(text).contains("\\begin{document}")
        }.sorted()
        guard roots.count == 1, let main = roots.first else { throw TeXArchive.failure("无法唯一确定主文件") }
        mainFile = main
    }

    mutating func expanded() throws -> String {
        let joined = try include(mainFile, stack: [])
        let definitions = try collectDefinitions(joined)
        return try expand(definitions, depth: 0)
    }

    private mutating func include(_ path: String, stack: [String]) throws -> String {
        try Task.checkCancellation()
        guard stack.count < 20, !stack.contains(path), let data = files[path], data.count <= 8_000_000,
            let text = String(data: data, encoding: .utf8)
        else { throw TeXArchive.failure("包含文件缺失、循环或无法读取") }
        var cursor = TeXCursor(Self.withoutComments(text))
        var result = ""
        while !cursor.ended {
            if cursor.peek == "\\", let literal = try cursor.literalEnvironment() {
                result += literal
                continue
            }
            if cursor.peek == "\\" {
                let start = cursor.index
                let command = cursor.command()
                if ["input", "include"].contains(command) {
                    let reference: String
                    cursor.skipSpace()
                    if cursor.peek == "{" {
                        reference = try cursor.group()
                    } else {
                        let begin = cursor.index
                        while let c = cursor.peek, !c.isWhitespace, c != "\\" { cursor.index += 1 }
                        reference = String(cursor.characters[begin..<cursor.index])
                    }
                    let target = try resolve(reference, relativeTo: path, extensions: ["tex"])
                    result += try include(target, stack: stack + [path])
                } else if command == "bibliography" {
                    _ = try cursor.group()
                    let name = (mainFile as NSString).deletingPathExtension + ".bbl"
                    guard files[name] != nil else { throw TeXArchive.failure("缺少已生成的参考文献文件") }
                    result += try include(name, stack: stack + [path])
                } else if command == "includegraphics" {
                    if cursor.peek == "*" { cursor.index += 1 }
                    _ = try cursor.optional()
                    let reference = try cursor.group()
                    let asset = try resolve(
                        reference, relativeTo: path, extensions: ["pdf", "png", "jpg", "jpeg", "svg", "eps"])
                    result += "\\includegraphics{" + asset + "}"
                } else {
                    result += String(cursor.characters[start..<cursor.index])
                }
            } else {
                result.append(cursor.peek!)
                cursor.index += 1
            }
            guard result.utf8.count <= 8_000_000 else { throw TeXArchive.failure("展开后的源码过大") }
        }
        return result
    }

    private func resolve(_ reference: String, relativeTo path: String, extensions: [String]) throws -> String {
        let reference = try TeXArchive.safePath(reference.trimmingCharacters(in: .whitespacesAndNewlines))
        let directory = (path as NSString).deletingLastPathComponent
        let bases = directory.isEmpty ? [reference] : [directory + "/" + reference, reference]
        for base in bases {
            let candidates = [base] + extensions.map { base + "." + $0 }
            if let found = candidates.first(where: { files[$0] != nil }) { return found }
        }
        throw TeXArchive.failure("源码引用的文件缺失")
    }

    private mutating func collectDefinitions(_ text: String) throws -> String {
        var cursor = TeXCursor(text)
        var result = ""
        var inDocument = false
        var groupDepth = 0
        while !cursor.ended {
            if cursor.peek == "\\", let literal = try cursor.literalEnvironment() {
                result += literal
                continue
            }
            if cursor.peek != "\\" {
                if cursor.peek == "{" { groupDepth += 1 }
                if cursor.peek == "}" { groupDepth -= 1 }
                result.append(cursor.peek!)
                cursor.index += 1
                continue
            }
            let start = cursor.index
            let command = cursor.command()
            if command == "begin" {
                let saved = cursor.index
                if (try? cursor.group()) == "document" { inDocument = true }
                cursor.index = saved
            }
            guard ["newcommand", "renewcommand", "providecommand", "def"].contains(command) else {
                result += String(cursor.characters[start..<cursor.index])
                continue
            }
            guard !inDocument, groupDepth == 0 else { throw TeXArchive.failure("正文或局部作用域中的宏定义尚不支持") }
            if cursor.peek == "*" { cursor.index += 1 }
            cursor.skipSpace()
            let name: String
            if cursor.peek == "{" {
                var nameCursor = TeXCursor(try cursor.group())
                name = nameCursor.command()
                guard nameCursor.ended else { throw TeXArchive.failure("宏名称无效") }
            } else {
                name = cursor.command()
            }
            guard !name.isEmpty, macros.count < 500 else { throw TeXArchive.failure("宏定义过多或无效") }
            guard macros[name] == nil || command == "providecommand" else {
                throw TeXArchive.failure("同名宏被重新定义")
            }
            var arguments = 0
            var defaultArgument: String?
            if command == "def" {
                while cursor.peek == "#" {
                    cursor.index += 1
                    arguments += 1
                    guard cursor.peek == Character(String(arguments)), arguments <= 9 else {
                        throw TeXArchive.failure("不支持带分隔符的宏")
                    }
                    cursor.index += 1
                }
            } else if let count = try cursor.optional() {
                guard let number = Int(count), (0...9).contains(number) else { throw TeXArchive.failure("宏参数无效") }
                arguments = number
                defaultArgument = try cursor.optional()
            }
            let body = try cursor.group()
            if command != "providecommand" || macros[name] == nil {
                macros[name] = Macro(arguments: arguments, defaultArgument: defaultArgument, body: body)
            }
        }
        return result
    }

    private mutating func expand(_ text: String, depth: Int) throws -> String {
        guard depth < 30 else { throw TeXArchive.failure("宏展开循环或层级过深") }
        try Task.checkCancellation()
        var cursor = TeXCursor(text)
        var result = ""
        while !cursor.ended {
            if cursor.peek == "\\", let literal = try cursor.literalEnvironment() {
                result += literal
                continue
            }
            let start = cursor.index
            if cursor.peek == "\\" {
                let command = cursor.command()
                if let macro = macros[command] {
                    var arguments: [String] = []
                    if let defaultArgument = macro.defaultArgument {
                        arguments.append(try cursor.optional() ?? defaultArgument)
                    }
                    while arguments.count < macro.arguments {
                        cursor.skipSpace()
                        if cursor.peek == "{" {
                            arguments.append(try cursor.group())
                        } else if cursor.peek == "\\" {
                            arguments.append("\\" + cursor.command())
                        } else if let c = cursor.peek {
                            arguments.append(String(c))
                            cursor.index += 1
                        } else {
                            throw TeXArchive.failure("宏参数缺失")
                        }
                    }
                    var body = ""
                    var value = TeXCursor(macro.body)
                    while !value.ended {
                        if value.peek == "#" {
                            value.index += 1
                            guard let c = value.peek, let index = Int(String(c)), index > 0, index <= arguments.count
                            else {
                                throw TeXArchive.failure("宏参数引用无效")
                            }
                            body += arguments[index - 1]
                            value.index += 1
                        } else {
                            body.append(value.peek!)
                            value.index += 1
                        }
                    }
                    expandedCharacters += body.utf8.count
                    guard expandedCharacters <= 8_000_000 else { throw TeXArchive.failure("宏展开超过限制") }
                    result += try expand(body, depth: depth + 1)
                    continue
                }
            } else {
                cursor.index += 1
            }
            result += String(cursor.characters[start..<cursor.index])
        }
        guard result.utf8.count <= 8_000_000 else { throw TeXArchive.failure("源码展开超过限制") }
        return result
    }

    static func withoutComments(_ text: String) -> String {
        var cursor = TeXCursor(text)
        var result = ""
        while !cursor.ended {
            if cursor.peek == "\\", let literal = try? cursor.literalEnvironment() {
                result += literal
                continue
            }
            let c = cursor.peek!
            cursor.index += 1
            if c == "\\" {
                result.append(c)
                if let next = cursor.peek {
                    result.append(next)
                    cursor.index += 1
                }
            } else if c == "%" {
                while let next = cursor.peek, next != "\n" { cursor.index += 1 }
                if cursor.peek == "\n" { cursor.index += 1 }
            } else {
                result.append(c)
            }
        }
        return result
    }
}
