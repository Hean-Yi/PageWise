import SwiftUI

/// Kept inside the reading surface so its buttons do not take ownership of the PDFKit selection.
struct PDFSelectionTools: View {
    let model: ReaderModel
    let anchor: CGRect
    let consumeSelection: () -> Bool

    var body: some View {
        PDFSelectionToolsLayout(anchor: anchor) {
            HStack(spacing: 1) {
                Button {
                    guard consumeSelection() else { return }
                    model.highlightSelection()
                } label: {
                    Label("高亮", systemImage: "highlighter").labelStyle(ReaderSymbolLabelStyle())
                        .padding(.horizontal, 8).readerIconTarget(macOS: 30)
                }
                if model.hasPDFNoteSelection {
                    Rectangle().fill(ReaderTheme.line).frame(width: 1, height: 16).accessibilityHidden(true)
                    Button {
                        guard consumeSelection() else { return }
                        Task { await model.beginPDFReadingNote() }
                    } label: {
                        Label("记笔记", readerIcon: .annotation, size: 15)
                            .padding(.horizontal, 8).readerIconTarget(macOS: 30)
                    }
                }
            }
            .readerIconButtonStyle(.plain).font(.callout).foregroundStyle(ReaderTheme.ink)
            .padding(3)
            .readerGlassSurface(in: RoundedRectangle(cornerRadius: 9), bordered: true)
            .shadow(color: .black.opacity(0.13), radius: 6, y: 2)
            .accessibilityElement(children: .contain).accessibilityLabel("选文操作")
        }
    }
}

struct PDFSelectionToolsLayout: Layout {
    let anchor: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let toolbar = subviews.first else { return }
        let size = toolbar.sizeThatFits(.unspecified)
        let region = anchor.offsetBy(dx: bounds.minX, dy: bounds.minY)
        let point = Self.origin(for: size, near: region, in: bounds)
        toolbar.place(at: point, anchor: .topLeading, proposal: ProposedViewSize(size))
    }

    static func origin(for size: CGSize, near anchor: CGRect, in bounds: CGRect) -> CGPoint {
        let edge: CGFloat = 6
        let gap: CGFloat = 8
        let usable = bounds.insetBy(dx: edge, dy: edge)
        let above = anchor.minY - gap - size.height
        let below = anchor.maxY + gap
        #if os(iOS)
            // Keep the space above the selection available for the system text-editing controls.
            let y = below + size.height <= usable.maxY ? below : above
        #else
            let y = above >= usable.minY ? above : below
        #endif
        return CGPoint(
            x: max(usable.minX, min(anchor.midX - size.width / 2, usable.maxX - size.width)),
            y: max(usable.minY, min(y, usable.maxY - size.height)))
    }
}
