import PaperReaderKit

@MainActor final class WorkflowCredentials: ModelCredentialStore {
    var values = ["model-key": "test-only"]
    func load(account: String) -> String { values[account] ?? "" }
    func save(_ value: String, account: String) {
        values[account] = value.isEmpty ? nil : value
    }
}
