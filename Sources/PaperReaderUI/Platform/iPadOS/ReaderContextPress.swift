#if os(iOS)
    import SwiftUI
    import UIKit

    struct ReaderContextPress: UIGestureRecognizerRepresentable {
        let action: (CGPoint) -> Void
        func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
            let press = UILongPressGestureRecognizer()
            press.allowableMovement = 8
            press.cancelsTouchesInView = false
            return press
        }

        func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
            if recognizer.state == .began { action(context.converter.localLocation) }
        }
    }

    struct ReaderContextTap: UIGestureRecognizerRepresentable {
        let action: (CGPoint) -> Void
        func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
            let tap = UITapGestureRecognizer()
            tap.buttonMaskRequired = .secondary
            return tap
        }

        func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
            if recognizer.state == .ended { action(context.converter.localLocation) }
        }
    }
#endif
