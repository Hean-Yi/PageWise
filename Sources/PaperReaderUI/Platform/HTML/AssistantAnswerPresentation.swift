import PaperReaderKit
import SwiftUI
import WebKit

/// Permit native text only when Marked would produce a single, unformatted paragraph.
/// An append-only stream can cross this boundary once, when it first acquires markup.
enum AssistantAnswerPresentation {
    private static let markup = CharacterSet(charactersIn: "\n\r\t`*_~$\\[]<>#|&")

    static func usesNativeText(_ text: String) -> Bool {
        guard let first = text.first else { return true }
        guard !first.isWhitespace, !"-+=".contains(first), text.rangeOfCharacter(from: markup) == nil else {
            return false
        }
        if first.isNumber, text.firstMatch(of: /^\d{1,9}[.)]/) != nil { return false }
        return true
    }
}

struct AssistantAnswerMeasurement {
    let width: CGFloat
    let height: CGFloat
    let fontSize: CGFloat

    func fits(width proposed: CGFloat?, fontSize: CGFloat) -> Bool {
        guard let proposed else { return false }
        return abs(width - proposed) < 0.5 && self.fontSize == fontSize
    }
}

/// Use exact, previously measured rich-text dimensions while WebKit rejoins a lazy stack.
struct AssistantAnswerLayout: Layout {
    let height: CGFloat?
    let restored: AssistantAnswerMeasurement?
    let fontSize: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        if let height { return CGSize(width: width, height: height) }
        if let restored, restored.fits(width: proposal.width, fontSize: fontSize) {
            return CGSize(width: width, height: restored.height)
        }
        return subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews { view.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}

/// Keep the last compiled output for a bounded number of retired rows. Two idle pages also
/// retain their local document, so reversing a scroll does not have to launch WebKit again.
@MainActor enum AssistantPageCache {
    struct Snapshot {
        let request: AssistantMarkdownCanvas.Request
        let answer: RenderedAssistantAnswer
        let measurement: AssistantAnswerMeasurement?
    }

    struct Page {
        let view: WKWebView
        let displayed: AssistantMarkdownCanvas.Request
        let measurement: AssistantAnswerMeasurement?
    }

    private static var snapshots: [Snapshot] = []
    private static var idle: [Page] = []

    static func snapshot(for request: AssistantMarkdownCanvas.Request) -> Snapshot? {
        snapshots.last { $0.request == request }
    }

    static func take(for request: AssistantMarkdownCanvas.Request) -> Page? {
        if let match = idle.lastIndex(where: { $0.displayed == request }) { return idle.remove(at: match) }
        return idle.popLast()
    }

    static func retire(_ view: WKWebView, snapshot: Snapshot) {
        // Avoid retaining exceptionally large answers (especially expanded MathML) twice.
        guard snapshot.answer.html.utf8.count + snapshot.request.markdown.utf8.count <= 256 * 1024 else { return }
        snapshots.removeAll { $0.request == snapshot.request }
        if snapshots.count == 16 { snapshots.removeFirst() }
        snapshots.append(snapshot)
        if idle.count == 2 { idle.removeFirst() }
        idle.append(Page(view: view, displayed: snapshot.request, measurement: snapshot.measurement))
    }
}
