#if os(macOS)
    import AppKit
    import SwiftUI

    struct ReaderMenuLocation {
        let point: CGPoint
        let windowNumber: Int

        @MainActor init?(event: NSEvent) {
            guard let window = event.window else { return nil }
            point = event.locationInWindow
            windowNumber = window.windowNumber
        }

    }

    /// Hold one popover per invocation. Shelf geometry changes must not re-present it during AppKit layout.
    struct ReaderMenuAnchor: NSViewRepresentable {
        @Binding var open: Bool
        let title: String
        let items: () -> [ReaderMenuItem]
        let width: CGFloat
        let location: ReaderMenuLocation?
        var makePopover: () -> NSPopover = { NSPopover() }
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        init(
            open: Binding<Bool>, title: String, items: @escaping () -> [ReaderMenuItem], width: CGFloat,
            location: ReaderMenuLocation?
        ) {
            _open = open
            self.title = title
            self.items = items
            self.width = width
            self.location = location
        }

        final class Anchor: NSView {
            override var isFlipped: Bool { true }
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }

        @MainActor final class Coordinator: NSObject, NSPopoverDelegate {
            var popover: NSPopover?
            var pending: Task<Void, Never>?
            var requested = false
            var didClose: (() -> Void)?

            func popoverDidClose(_ notification: Notification) {
                guard let closed = notification.object as? NSPopover, closed === popover else { return }
                popover = nil
                if requested {
                    requested = false
                    didClose?()
                }
            }

            func cancel() {
                requested = false
                pending?.cancel()
                didClose = nil
                let popup = popover
                popover = nil
                Task { popup?.close() }
            }
        }

        func makeCoordinator() -> Coordinator { Coordinator() }
        func makeNSView(context: Context) -> Anchor { Anchor() }

        // A non-interactive NSView has no intrinsic size. Match the actual trigger even inside fixedSize buttons.
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: Anchor, context: Context) -> CGSize? {
            proposal.replacingUnspecifiedDimensions(by: .zero)
        }

        func updateNSView(_ anchor: Anchor, context: Context) {
            let coordinator = context.coordinator
            guard open != coordinator.requested else { return }
            coordinator.requested = open
            coordinator.pending?.cancel()
            // Opening another popover can close its predecessor and run a nested AppKit layout pass.
            // Let SwiftUI finish updating the anchor before either presentation operation.
            coordinator.pending = Task { @MainActor [weak anchor, weak coordinator] in
                guard !Task.isCancelled, let coordinator else { return }
                if !open {
                    coordinator.popover?.performClose(nil)
                    return
                }
                guard let anchor, let window = anchor.window, let content = window.contentView else {
                    open = false
                    return
                }
                guard coordinator.popover == nil else { return }
                let visible = anchor.bounds.intersection(anchor.visibleRect)
                guard !visible.isEmpty else {
                    open = false
                    return
                }
                let popup = makePopover()
                coordinator.popover = popup
                coordinator.didClose = { if open { open = false } }
                popup.delegate = coordinator
                popup.behavior = .transient
                popup.animates = !reduceMotion
                let panel = ReaderMenuPanel(title: title, items: items(), width: width) { open = false }
                let host = NSHostingController(rootView: panel)
                // AppKit positions the arrow using the initial content size. A hosting controller starts at
                // 320 × 320; shrinking after show leaves the arrow at the old window origin.
                let size = host.view.fittingSize
                host.view.setFrameSize(size)
                host.preferredContentSize = size
                popup.contentViewController = host
                popup.contentSize = size
                // Primary clicks, keyboard and accessibility all open from the control's visible bounds.
                // A context click belongs to its event's window, even if the overlay moved before presentation.
                let pointer = location.flatMap { $0.windowNumber == window.windowNumber ? $0.point : nil }
                let trigger =
                    pointer.map { NSRect(origin: $0, size: NSSize(width: 1, height: 1)) }
                    ?? anchor.convert(visible, to: nil)
                let anchorCanFollow = pointer.map { visible.contains(anchor.convert($0, from: nil)) } ?? true
                let source: NSView = anchorCanFollow ? anchor : content
                let viewport = window.contentLayoutRect
                let below = trigger.minY - viewport.minY
                let above = viewport.maxY - trigger.maxY
                let showBelow = below >= size.height + 14 || below >= above
                let edge: NSRectEdge = showBelow == source.isFlipped ? .maxY : .minY
                popup.show(relativeTo: source.convert(trigger, from: nil), of: source, preferredEdge: edge)
            }
        }

        static func dismantleNSView(_ nsView: Anchor, coordinator: Coordinator) {
            coordinator.cancel()
        }
    }
#endif
