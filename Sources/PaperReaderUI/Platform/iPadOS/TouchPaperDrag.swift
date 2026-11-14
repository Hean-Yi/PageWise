#if os(iOS)
    import PaperReaderKit
    import SwiftUI
    import UIKit

    /// The system owns pickup, cursor tracking and cancellation on iPad, including drops outside our window.
    struct TouchPaperDrag: UIViewRepresentable {
        let paper: Paper
        let progress: ReadingProgress
        let open: () -> Void
        let begin: () -> Void
        let end: () -> Void
        let accepts: (UUID) -> Bool
        let hover: (UUID) -> Void
        let receive: (UUID) -> Bool

        func makeUIView(context: Context) -> TouchPaperDragView { TouchPaperDragView() }
        func updateUIView(_ view: TouchPaperDragView, context: Context) {
            view.configuration = self
        }
    }

    final class TouchPaperDragView: UIView {
        var configuration: TouchPaperDrag?

        override init(frame: CGRect) {
            super.init(frame: frame)
            let drag = UIDragInteraction(delegate: self)
            drag.isEnabled = true
            addInteraction(drag)
            addInteraction(UIDropInteraction(delegate: self))
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openPaper)))
            isAccessibilityElement = false
        }
        required init?(coder: NSCoder) { nil }
        @objc private func openPaper() { configuration?.open() }
    }

    extension TouchPaperDragView: UIDragInteractionDelegate {
        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession)
            -> [UIDragItem]
        {
            guard let configuration else { return [] }
            configuration.begin()
            let item = UIDragItem(itemProvider: PaperShelfDrag.provider(configuration.paper.id))
            item.localObject = configuration.paper.id
            item.previewProvider = { [weak self] in
                guard let self else { return nil }
                return self.preview()
            }
            return [item]
        }
        private func preview() -> UIDragPreview? {
            guard let configuration else { return nil }
            let renderer = ImageRenderer(
                content: BookCoverView(paper: configuration.paper, progress: configuration.progress)
                    .frame(width: bounds.width, height: bounds.height))
            renderer.scale = window?.screen.scale ?? 2
            guard let image = renderer.uiImage else { return nil }
            let parameters = UIDragPreviewParameters()
            parameters.backgroundColor = .clear
            return UIDragPreview(view: UIImageView(image: image), parameters: parameters)
        }
        func dragInteraction(
            _ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation
        ) {
            configuration?.end()
        }
        func dragInteraction(
            _ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: any UIDragSession
        )
            -> Bool
        { true }
    }

    extension TouchPaperDragView: UIDropInteractionDelegate {
        private func reference(_ session: any UIDropSession) -> UUID? {
            guard let id = session.localDragSession?.items.first?.localObject as? UUID,
                configuration?.accepts(id) == true
            else { return nil }
            return id
        }
        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
            reference(session) != nil
        }
        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession)
            -> UIDropProposal
        {
            guard let id = reference(session) else { return UIDropProposal(operation: .forbidden) }
            configuration?.hover(id)
            return UIDropProposal(operation: .move)
        }
        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
            guard let id = reference(session) else { return }
            configuration?.hover(id)
            _ = configuration?.receive(id)
        }
    }
#endif
