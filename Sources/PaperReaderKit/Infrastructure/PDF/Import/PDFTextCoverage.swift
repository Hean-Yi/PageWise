import Foundation
import PDFKit

/// Strict line coverage for retiring legacy whole-page HTML supplements.
/// This is intentionally not a word-percentage threshold.
enum PDFTextCoverage {
    static func normalized(_ value: String) -> String {
        let greek: [Character: String] = [
            "α": "alpha", "β": "beta", "γ": "gamma", "δ": "delta", "θ": "theta", "λ": "lambda", "μ": "mu", "π": "pi",
            "ρ": "rho", "σ": "sigma", "τ": "tau", "φ": "phi", "ω": "omega",
        ]
        return value.precomposedStringWithCompatibilityMapping.lowercased().reduce(into: "") { result, character in
            if let name = greek[character] {
                result += name
            } else if character.isLetter || character.isNumber {
                result.append(character)
            }
        }
    }

    static func repeatedMargins(in document: PDFDocument) -> Set<String> {
        var occurrences: [String: Int] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .cropBox)
            let selections =
                page.selection(for: NSRange(location: 0, length: page.numberOfCharacters))?.selectionsByLine() ?? []
            let margins = Set(
                selections.filter {
                    let rect = $0.bounds(for: page)
                    return rect.minY > bounds.maxY - bounds.height * 0.1
                        || rect.maxY < bounds.minY + bounds.height * 0.08
                }.map { normalized($0.string ?? "") }.filter { !$0.isEmpty })
            for text in margins { occurrences[text, default: 0] += 1 }
        }
        return Set(occurrences.filter { $0.value >= 2 }.keys)
    }

    static func covers(_ page: PDFPage, sourcePage: Int, corpus: String, repeatedMargins: Set<String>) -> Bool {
        let bounds = page.bounds(for: .cropBox)
        let selections =
            page.selection(for: NSRange(location: 0, length: page.numberOfCharacters))?.selectionsByLine() ?? []
        guard !selections.isEmpty else { return false }
        var seen: [String: Int] = [:]
        for selection in selections {
            let text = normalized(selection.string ?? "")
            if text.isEmpty { continue }
            let rect = selection.bounds(for: page)
            let margin = rect.minY > bounds.maxY - bounds.height * 0.1 || rect.maxY < bounds.minY + bounds.height * 0.08
            if margin && (repeatedMargins.contains(text) || text == String(sourcePage + 1)) { continue }
            seen[text, default: 0] += 1
            guard corpus.components(separatedBy: text).count - 1 >= seen[text, default: 0] else { return false }
        }
        return !seen.isEmpty
    }
}
