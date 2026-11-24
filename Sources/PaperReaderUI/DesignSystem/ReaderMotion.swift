import SwiftUI

enum ReaderMotion {
    static func feedback(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.14)
    }

    static func disclosure(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.23)
    }

    static func navigation(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.28)
    }

    static func arrival(y: CGFloat = 0) -> AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: y)), removal: .identity)
    }
}
