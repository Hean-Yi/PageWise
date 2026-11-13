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

/// Decorative paper shapes; navigation and actions remain real, accessible controls.
struct PaperIllustration: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(ReaderTheme.accent.opacity(0.07))
                .frame(width: 146, height: 186).rotationEffect(.degrees(-13)).offset(x: -22, y: 6)
            RoundedRectangle(cornerRadius: 10).fill(ReaderTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ReaderTheme.line))
                .frame(width: 146, height: 186).rotationEffect(.degrees(9)).offset(x: 20, y: -3)
            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(ReaderTheme.accent).frame(width: 36, height: 5)
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(ReaderTheme.ink.opacity(0.65)).frame(width: 92, height: 6)
                    RoundedRectangle(cornerRadius: 2).fill(ReaderTheme.ink.opacity(0.65)).frame(width: 64, height: 6)
                }.padding(.bottom, 5)
                ForEach(0..<5) { i in
                    RoundedRectangle(cornerRadius: 1).fill(i == 2 ? ReaderTheme.accent.opacity(0.3) : ReaderTheme.line)
                        .frame(width: i == 4 ? 68 : 104, height: i == 2 ? 7 : 3)
                }
                Spacer(minLength: 0)
            }.padding(21).frame(width: 146, height: 186)
                .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ReaderTheme.line))
                .shadow(color: .black.opacity(0.07), radius: 16, x: 0, y: 10)
        }.frame(width: 220, height: 220).accessibilityHidden(true)
    }
}
