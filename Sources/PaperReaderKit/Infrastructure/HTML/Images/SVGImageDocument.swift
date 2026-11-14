import Foundation

/// SVG remains a separate image document, so its styles and IDs cannot affect the reader or other figures.
struct SVGImageDocument: Sendable {
    indirect enum Node: Sendable {
        case element(String, [String: String], [Node])
        case text(String)
    }
    let root: Node
    let width: Double
    let height: Double
    let imageReferences: Set<String>
    let isAnimated: Bool

    var coverageText: String {
        func labels(_ node: Node, inText: Bool = false) -> String {
            switch node {
            case .text(let value): return inText ? value : ""
            case .element(let name, let attrs, let children):
                if ["defs", "style", "title", "desc"].contains(name) { return "" }
                let glyph = ["use", "path"].contains(name) ? attrs["data-text"] ?? "" : ""
                return glyph + children.map { labels($0, inText: inText || name == "text" || name == "tspan") }.joined()
            }
        }
        return labels(root)
    }

    static func parse(_ data: Data) throws -> SVGImageDocument {
        guard data.count <= 8_000_000,
            var xml = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
            !xml.localizedCaseInsensitiveContains("<!ENTITY"), !xml.contains("<?xml-stylesheet")
        else { throw ReaderError.message("SVG 内容无法安全读取。") }
        // Common exporters include the public SVG DTD. It is not needed to render the figure.
        if let range = xml.range(of: #"<!DOCTYPE[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            guard !xml[range].contains("[") else { throw ReaderError.message("SVG 含外部实体定义。") }
            xml.removeSubrange(range)
        }
        xml = xml.replacingOccurrences(of: #"<\?xml[^>]*\?>"#, with: "", options: .regularExpression)
        let parser = XMLParser(data: Data(xml.utf8))
        let delegate = SVGTreeParser()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.failure == nil, let root = delegate.root,
            case .element(let name, let attrs, _) = root, name == "svg"
        else { throw delegate.failure ?? ReaderError.message("SVG 文件损坏或使用了无法保留的结构。") }
        let box = attrs["viewBox"]?.split { $0.isWhitespace || $0 == "," }.compactMap { Double($0) }
        let boxWidth = box?.count == 4 ? box?[2] : nil
        let boxHeight = box?.count == 4 ? box?[3] : nil
        let width = length(attrs["width"]) ?? boxWidth
        let height = length(attrs["height"]) ?? boxHeight
        guard let width, let height, width.isFinite, height.isFinite, width > 0, height > 0,
            width <= 100_000, height <= 100_000, delegate.references.isSubset(of: delegate.ids)
        else { throw ReaderError.message("SVG 尺寸或内部图形引用不完整。") }
        return SVGImageDocument(
            root: root, width: width, height: height,
            imageReferences: delegate.images, isAnimated: delegate.animated)
    }

    func dataURI(replacing images: [String: String]) throws -> String {
        func serialize(_ node: Node, isRoot: Bool = false) throws -> String {
            switch node {
            case .text(let text): return HTMLPaperParser.escape(text)
            case .element(let name, var attrs, let children):
                if isRoot {
                    attrs["xmlns"] = "http://www.w3.org/2000/svg"
                    attrs["xmlns:xlink"] = "http://www.w3.org/1999/xlink"
                    attrs["width"] = String(width)
                    attrs["height"] = String(height)
                }
                if ["image", "feImage", "img"].contains(name) {
                    for key in ["href", "xlink:href", "src"] {
                        if let reference = attrs[key], !reference.hasPrefix("#") {
                            guard let embedded = images[reference] else { throw ReaderError.message("SVG 内嵌图片缺失。") }
                            attrs[key] = embedded
                        }
                    }
                }
                let attributes = attrs.sorted { $0.key < $1.key }.map {
                    " \($0.key)=\"\(HTMLPaperParser.escape($0.value))\""
                }.joined()
                return "<\(name)\(attributes)>" + (try children.map { try serialize($0) }.joined()) + "</\(name)>"
            }
        }
        return "data:image/svg+xml;base64," + Data(try serialize(root, isRoot: true).utf8).base64EncodedString()
    }

    private static func length(_ value: String?) -> Double? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let units: [(String, Double)] = [
            ("px", 1), ("pt", 96 / 72), ("pc", 16), ("in", 96), ("cm", 96 / 2.54), ("mm", 96 / 25.4),
        ]
        for (unit, scale) in units where clean.hasSuffix(unit) {
            return Double(clean.dropLast(unit.count)).map { $0 * scale }
        }
        return Double(clean)
    }
}

private final class SVGTreeParser: NSObject, XMLParserDelegate {
    struct Frame {
        var name: String
        var attrs: [String: String]
        var children: [SVGImageDocument.Node] = []
    }
    var root: SVGImageDocument.Node?
    var failure: (any Error)?
    var ids: Set<String> = []
    var references: Set<String> = []
    var images: Set<String> = []
    var animated = false
    private var stack: [Frame] = []
    private var skipped = 0
    private var count = 0
    private static let allowed: Set<String> = [
        "svg", "g", "defs", "symbol", "use", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon",
        "text", "tspan", "textPath", "title", "desc", "style", "clipPath", "mask", "pattern", "marker",
        "linearGradient", "radialGradient", "stop", "image", "switch", "view", "filter", "feBlend", "feColorMatrix",
        "feComponentTransfer", "feComposite", "feConvolveMatrix", "feDiffuseLighting", "feDisplacementMap",
        "feDistantLight", "feDropShadow", "feFlood", "feFuncA", "feFuncB", "feFuncG", "feFuncR", "feGaussianBlur",
        "feImage", "feMerge", "feMergeNode", "feMorphology", "feOffset", "fePointLight", "feSpecularLighting",
        "feSpotLight", "feTile", "feTurbulence", "foreignObject",
        "div", "span", "p", "br", "b", "strong", "i", "em", "sub", "sup", "table", "tbody", "tr", "td", "th", "img",
        "a",
    ]

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
        attributes: [String: String]
    ) {
        let rawName = elementName.split(separator: ":").last.map(String.init) ?? elementName
        let name = Self.allowed.first { $0.lowercased() == rawName.lowercased() } ?? rawName
        if skipped > 0 {
            skipped += 1
            return
        }
        if ["script", "metadata", "animate", "animatemotion", "animatetransform", "set", "discard"].contains(
            name.lowercased())
            || elementName.hasPrefix("sodipodi:") || elementName.hasPrefix("inkscape:")
        {
            if name.lowercased().hasPrefix("animate") || name == "set" { animated = true }
            skipped = 1
            return
        }
        count += 1
        guard Self.allowed.contains(name), stack.count < 128, count <= 100_000 else {
            fail(parser, "SVG 结构超出支持范围。")
            return
        }
        var attrs: [String: String] = [:]
        let camelAttributes = [
            "viewBox", "preserveAspectRatio", "clipPathUnits", "maskUnits", "maskContentUnits",
            "gradientUnits", "gradientTransform", "spreadMethod", "patternUnits", "patternContentUnits",
            "patternTransform",
            "markerWidth", "markerHeight", "markerUnits", "refX", "refY", "textLength", "lengthAdjust", "filterUnits",
            "primitiveUnits", "stdDeviation", "baseFrequency", "numOctaves", "kernelMatrix", "kernelUnitLength",
            "keyPoints", "pathLength", "startOffset", "tableValues", "targetX", "targetY", "viewTarget",
            "attributeName", "edgeMode", "preserveAlpha", "surfaceScale", "diffuseConstant", "specularConstant",
            "specularExponent", "limitingConeAngle", "pointsAtX", "pointsAtY", "pointsAtZ", "xChannelSelector",
            "yChannelSelector",
        ]
        for (rawKey, value) in attributes {
            let key = camelAttributes.first { $0.lowercased() == rawKey.lowercased() } ?? rawKey
            if key.lowercased().hasPrefix("on") || key == "xml:base" { continue }
            if name == "a" && ["href", "xlink:href", "target"].contains(key) { continue }
            if key == "id" {
                guard ids.insert(value).inserted else {
                    fail(parser, "SVG 含重复图形标识。")
                    return
                }
            }
            if ["href", "xlink:href", "src"].contains(key) {
                if value.hasPrefix("#") {
                    references.insert(String(value.dropFirst()))
                } else if ["image", "feImage", "img"].contains(name) {
                    images.insert(value)
                } else {
                    fail(parser, "SVG 依赖未内嵌的外部图形。")
                    return
                }
            }
            if key == "style" || value.lowercased().contains("url(") {
                do { try inspectCSS(value) } catch {
                    failure = error
                    parser.abortParsing()
                    return
                }
            }
            attrs[key] = value
        }
        if stack.contains(where: { $0.name == "foreignObject" }),
            [
                "div", "span", "p", "br", "b", "strong", "i", "em", "sub", "sup", "table", "tbody", "tr", "td", "th",
                "img", "a",
            ].contains(name)
        {
            attrs["xmlns"] = "http://www.w3.org/1999/xhtml"
        }
        stack.append(Frame(name: name, attrs: attrs))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipped == 0, !stack.isEmpty else { return }
        stack[stack.count - 1].children.append(.text(string))
    }
    func parser(_ parser: XMLParser, foundCDATA cdataBlock: Data) {
        if let text = String(data: cdataBlock, encoding: .utf8) {
            self.parser(parser, foundCharacters: text)
        } else {
            fail(parser, "SVG 样式编码无法读取。")
        }
    }
    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
    ) {
        if skipped > 0 {
            skipped -= 1
            return
        }
        guard let frame = stack.popLast() else { return }
        if frame.name == "style" {
            let css = frame.children.compactMap { if case .text(let value) = $0 { value } else { nil } }.joined()
            do { try inspectCSS(css) } catch {
                failure = error
                parser.abortParsing()
                return
            }
        }
        let node = SVGImageDocument.Node.element(frame.name, frame.attrs, frame.children)
        if stack.isEmpty { root = node } else { stack[stack.count - 1].children.append(node) }
    }

    private func inspectCSS(_ value: String) throws {
        let lower = value.lowercased()
        if lower.contains("@import") || lower.contains("@font-face") || lower.contains("javascript:")
            || value.contains("\\")
        {
            throw ReaderError.message("SVG 依赖外部样式、字体或活动内容。")
        }
        if lower.contains("animation") || lower.contains("transition") || lower.contains("@keyframes") {
            throw ReaderError.message("SVG 使用动态样式，需查看原版静态图。")
        }
        let expression = try NSRegularExpression(
            pattern: #"url\(\s*['\"]?([^'\")\s]+)['\"]?\s*\)"#, options: [.caseInsensitive])
        let matches = expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
        for match in matches {
            guard let range = Range(match.range(at: 1), in: value), value[range].hasPrefix("#") else {
                throw ReaderError.message("SVG 样式引用了外部资源。")
            }
            references.insert(String(value[range].dropFirst()))
        }
        if lower.contains("url(") && matches.isEmpty { throw ReaderError.message("SVG 资源引用格式无法确认。") }
    }
    private func fail(_ parser: XMLParser, _ message: String) {
        failure = ReaderError.message(message)
        parser.abortParsing()
    }
}
