import CoreText
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

enum ReaderTheme {
    static let accent = adaptive(light: 0x9F503A, dark: 0xE8A086)
    static let canvas = adaptive(light: 0xF9F8F3, dark: 0x23221E)
    static let surface = adaptive(light: 0xFFFDF8, dark: 0x2C2B26)
    static let sidebar = adaptive(light: 0xF1EFE8, dark: 0x1E1D1A)
    static let elevated = adaptive(light: 0xEDE8DD, dark: 0x35322B)
    static let ink = adaptive(light: 0x292822, dark: 0xF0EEE7)
    static let muted = adaptive(light: 0x69665E, dark: 0xB6B2A7)
    static let line = adaptive(light: 0xDFDDD3, dark: 0x44413A)
    static let searchHighlight = adaptive(light: 0xF5DFA5, dark: 0x66502B)

    private struct EditorialFontKey: Hashable {
        let sizeTenths: Int
        let weight: Font.Weight
    }

    @MainActor private static var editorialCache: [EditorialFontKey: Font] = [:]

    @MainActor static func editorial(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let key = EditorialFontKey(sizeTenths: Int((size * 10).rounded()), weight: weight)
        if let cached = editorialCache[key] { return cached }
        let font = Font(CTFontCreateWithFontDescriptor(editorialDescriptor, size, nil)).weight(weight)
        editorialCache[key] = font
        return font
    }

    @MainActor private static let editorialDescriptor: CTFontDescriptor = {
        #if os(macOS)
            let system = NSFont.systemFont(ofSize: 17).fontDescriptor
        #else
            let system = UIFont.systemFont(ofSize: 17).fontDescriptor
        #endif
        let serif = (system.withDesign(.serif) ?? system) as CTFontDescriptor
        let songti = CTFontDescriptorCreateWithNameAndSize("STSongti-SC-Regular" as CFString, 0)
        return CTFontDescriptorCreateCopyWithAttributes(serif, [kCTFontCascadeListAttribute: [songti]] as CFDictionary)
    }()

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if os(macOS)
            Color(
                nsColor: NSColor(name: nil) { appearance in
                    let rgb = components(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
                    return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
                })
        #else
            Color(
                uiColor: UIColor { traits in
                    let rgb = components(traits.userInterfaceStyle == .dark ? dark : light)
                    return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
                })
        #endif
    }

    private static func components(_ hex: UInt32) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        (CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255)
    }
}
