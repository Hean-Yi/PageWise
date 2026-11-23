#if os(macOS)
    import SwiftUI

    extension FocusedValues {
        @Entry var readerSettingsPresentation: Binding<Bool>?
    }

    public struct ReaderSettingsCommands: Commands {
        @FocusedBinding(\.readerSettingsPresentation) private var presented

        public init() {}

        public var body: some Commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { presented = true }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(presented != false)
            }
        }
    }
#endif
