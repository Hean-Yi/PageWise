import Foundation

/// A plain-text label for bibliographic metadata. Structured equations stay in the source
/// notation when a single glyph cannot represent them faithfully.
public enum PaperTitle {
    public static func display(_ source: String) -> String {
        guard source.contains("$") || source.contains(#"\("#) || source.contains(#"\["#) else { return source }
        let text = source as NSString
        var result: NSMutableString?
        for match in mathSpans.matches(in: source, range: NSRange(location: 0, length: text.length)).reversed() {
            // The three alternatives capture the body of $/$$, \( and \[ respectively.
            guard let body = (2...4).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) else {
                continue
            }
            let token = text.substring(with: body).trimmingCharacters(in: .whitespaces)
            let glyph: String
            if let named = symbols[token] {
                glyph = named
            } else if token.count == 1, let character = token.first, character.isLetter {
                glyph = token
            } else {
                continue
            }
            if result == nil { result = NSMutableString(string: source) }
            result?.replaceCharacters(in: match.range, with: glyph)
        }
        return result.map { $0 as String } ?? source
    }

    // Match whole expressions before inspecting them. A closing dollar beside a price,
    // an escaped dollar, or a dollar inside an unsupported expression is not a new opener.
    private static let mathSpans = try! NSRegularExpression(
        pattern: #"""
            (?x)
            (?<![\\$]) (\${1,2})
            ( \h* (?:\\[A-Za-z]+|\p{L}\p{M}*) \h* | (?![\s$\p{Nd}]) (?:\\.|[^\\$\r\n])++ (?<!\s) )
            \1 (?![$\p{Nd}])
            | (?<!\\) \\\( (.*?) \\\)
            | (?<!\\) \\\[ (.*?) \\\]
            """#)

    private static let symbols = [
        #"\alpha"#: "α", #"\beta"#: "β", #"\gamma"#: "γ", #"\delta"#: "δ", #"\epsilon"#: "ϵ", #"\zeta"#: "ζ",
        #"\eta"#: "η", #"\theta"#: "θ", #"\iota"#: "ι", #"\kappa"#: "κ", #"\lambda"#: "λ", #"\mu"#: "μ",
        #"\nu"#: "ν", #"\xi"#: "ξ", #"\omicron"#: "ο", #"\pi"#: "π", #"\rho"#: "ρ", #"\sigma"#: "σ",
        #"\tau"#: "τ", #"\upsilon"#: "υ", #"\phi"#: "ϕ", #"\chi"#: "χ", #"\psi"#: "ψ", #"\omega"#: "ω",
        #"\Gamma"#: "Γ", #"\Delta"#: "Δ", #"\Theta"#: "Θ", #"\Lambda"#: "Λ", #"\Xi"#: "Ξ", #"\Pi"#: "Π",
        #"\Sigma"#: "Σ", #"\Upsilon"#: "Υ", #"\Phi"#: "Φ", #"\Psi"#: "Ψ", #"\Omega"#: "Ω",
        #"\varepsilon"#: "ε", #"\vartheta"#: "ϑ", #"\varkappa"#: "ϰ", #"\varpi"#: "ϖ", #"\varrho"#: "ϱ",
        #"\varsigma"#: "ς", #"\varphi"#: "φ",
    ]
}
