#if os(macOS)
    import SwiftUI

    extension FocusedValues {
        @Entry var readerSettingsPresentation: Binding<Bool>?
        @Entry var quickStartPresentation: Binding<Bool>?
    }

    public struct ReaderSettingsCommands: Commands {
        @FocusedBinding(\.readerSettingsPresentation) private var presented

        @FocusedBinding(\.quickStartPresentation) private var guidePresented

        public init() {}

        public var body: some Commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { presented = true }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(presented != false)
            }
            CommandGroup(replacing: .help) {
                Button("快速上手") { guidePresented = true }
                    .disabled(guidePresented != false)
            }
        }
    }
#endif
