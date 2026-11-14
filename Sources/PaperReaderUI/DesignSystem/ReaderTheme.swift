import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

enum ReaderTheme {
    static let accent = adaptive(light: (0.64, 0.30, 0.20), dark: (0.88, 0.57, 0.43))
    static let canvas = adaptive(light: (0.98, 0.975, 0.96), dark: (0.14, 0.135, 0.125))
    static let surface = adaptive(light: (1, 0.995, 0.985), dark: (0.18, 0.17, 0.155))
    static let sidebar = adaptive(light: (0.945, 0.935, 0.91), dark: (0.115, 0.11, 0.10))
    static let elevated = adaptive(light: (0.955, 0.94, 0.905), dark: (0.22, 0.20, 0.175))
    static let ink = Color.primary
    static let muted = Color.secondary
    static let line = Color.primary.opacity(0.09)

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        #if os(macOS)
            Color(
                nsColor: NSColor(name: nil) { appearance in
                    let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                    return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
                })
        #else
            Color(
                uiColor: UIColor { traits in
                    let c = traits.userInterfaceStyle == .dark ? dark : light
                    return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
                })
        #endif
    }
}
