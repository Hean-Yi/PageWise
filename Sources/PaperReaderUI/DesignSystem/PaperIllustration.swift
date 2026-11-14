import SwiftUI

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
