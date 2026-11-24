import SwiftUI

enum ReaderIconInteraction: Equatable, Sendable {
    case idle, hovered, pressed
}

extension EnvironmentValues {
    @Entry var readerIconInteraction: ReaderIconInteraction = .idle
}

extension View {
    func readerIconButtonStyle(_ style: PlainButtonStyle) -> some View {
        buttonStyle(ReaderIconActionStyle { $0.buttonStyle(PlainInkLabel()) })
    }

    func readerIconButtonStyle(_ style: some PrimitiveButtonStyle) -> some View {
        buttonStyle(ReaderIconActionStyle { $0.buttonStyle(style) })
    }

    func readerIconButtonStyle(_ style: some ButtonStyle) -> some View {
        buttonStyle(ReaderIconActionStyle { $0.buttonStyle(style) })
    }
}

private struct PlainInkLabel: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.transformEnvironment(\.readerIconInteraction) {
            if configuration.isPressed { $0 = .pressed }
        }
    }
}

/// Give a completed click enough time to register in the ink. The button still owns
/// pointer tracking, keyboard shortcuts, accessibility actions, and cancellation.
private struct ReaderIconActionStyle<Styled: View>: PrimitiveButtonStyle {
    let chrome: (Button<Configuration.Label>) -> Styled

    func makeBody(configuration: Configuration) -> some View {
        Action(configuration: configuration, chrome: chrome)
    }

    private struct Action: View {
        let configuration: PrimitiveButtonStyleConfiguration
        let chrome: (Button<PrimitiveButtonStyleConfiguration.Label>) -> Styled
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false
        @State private var release: Task<Void, Never>?

        var body: some View {
            let button = Button(role: configuration.role, action: activate) { configuration.label }
            chrome(button)
                .environment(\.readerIconInteraction, interaction)
                .onHover { hovered = $0 }
                .onDisappear {
                    release?.cancel()
                    release = nil
                    hovered = false
                }
        }

        private func activate() {
            guard enabled else { return }
            if !reduceMotion {
                release?.cancel()
                release = Task {
                    do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                    if !Task.isCancelled { release = nil }
                }
            }
            configuration.trigger()
        }

        private var interaction: ReaderIconInteraction {
            guard enabled, !reduceMotion else { return .idle }
            if release != nil { return .pressed }
            return hovered ? .hovered : .idle
        }
    }
}
