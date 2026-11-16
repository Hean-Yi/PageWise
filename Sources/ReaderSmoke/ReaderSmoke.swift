import Foundation

@main
struct ReaderSmoke {
    @MainActor static func main() async throws {
        let preview = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--tex-preview"
        let argument = preview ? CommandLine.arguments[2] : CommandLine.arguments.dropFirst().first ?? ".local/smoke"
        let directory = URL(fileURLWithPath: argument, isDirectory: true)
        try await TeXPreviewSmoke.run(root: preview ? directory : directory.appendingPathComponent(UUID().uuidString))
    }
}
