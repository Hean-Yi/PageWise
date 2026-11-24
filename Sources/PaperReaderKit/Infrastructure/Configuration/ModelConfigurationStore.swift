import Foundation

@MainActor public protocol ModelCredentialStore {
    func load(account: String) throws -> String
    func loadForRequest(account: String) async throws -> String
    /// An empty value removes the account.
    func save(_ value: String, account: String) throws
}

extension ModelCredentialStore {
    public func loadForRequest(account: String) async throws -> String { try load(account: account) }
}

public struct DeviceModelCredentials: ModelCredentialStore {
    public init() {}
    public func load(account: String) throws -> String { try KeychainStore.load(account: account) }
    public func loadForRequest(account: String) async throws -> String {
        // A system Keychain authorization prompt must not block the UI actor.
        let key = try await Task.detached(priority: .userInitiated) { try KeychainStore.load(account: account) }.value
        try Task.checkCancellation()
        return key
    }
    public func save(_ value: String, account: String) throws { try KeychainStore.save(value, account: account) }
}

@MainActor public struct ModelConfigurationStore {
    public struct SaveResult {
        public let settings: ModelSettings
        public let warning: String?
    }
    private let file: URL
    private let credentials: any ModelCredentialStore

    public init(directory: URL, credentials: any ModelCredentialStore = DeviceModelCredentials()) {
        file = directory.appendingPathComponent("model-settings.json")
        self.credentials = credentials
    }

    public func load() throws -> ModelSettings {
        guard FileManager.default.fileExists(atPath: file.path) else { return ModelSettings() }
        return try JSONDecoder().decode(ModelSettings.self, from: Data(contentsOf: file))
    }

    public func keyForRequest(_ settings: ModelSettings) async throws -> String {
        try await credentials.loadForRequest(account: settings.credentialID ?? "model-key")
    }

    public func keyForDraftRequest(_ draft: ModelSettings) async throws -> String {
        let saved = try load()
        guard try saved.endpointURL() == draft.endpointURL() else { return "" }
        return try await keyForRequest(saved)
    }

    public func save(_ draft: ModelSettings, key: String?, removeKey: Bool = false) throws -> SaveResult {
        let previous = try load()
        // Removing an existing credential must also work for incomplete legacy configurations.
        // Any accompanying configuration edit still requires the normal validation.
        let onlyRemovesCredential = removeKey && draft == previous
        var next = onlyRemovesCredential ? previous : try draft.normalized()
        let replacement = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !replacement.contains(where: { $0.isWhitespace }) else {
            throw ReaderError.message("API Key 中不能包含空格或换行。")
        }
        let replacesCredential =
            removeKey || !replacement.isEmpty || (try? previous.endpointURL()) != (try? next.endpointURL())
        next.credentialID = replacesCredential ? UUID().uuidString : previous.credentialID
        let data = try JSONEncoder().encode(next)
        let account = next.credentialID ?? "model-key"
        let writesKey = replacesCredential && !removeKey && !replacement.isEmpty
        if writesKey { try credentials.save(replacement, account: account) }
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            if writesKey {
                do { try credentials.save("", account: account) } catch {
                    throw ReaderError.message(
                        "设置未能保存，原配置仍然有效。新密钥的临时 Keychain 项未能清理，但不会用于模型请求；请检查钥匙串后重试。")
                }
            }
            throw ReaderError.message("设置未能保存，原配置仍然有效。请检查本地存储后重试。")
        }
        var warning: String?
        if replacesCredential {
            do { try credentials.save("", account: previous.credentialID ?? "model-key") } catch {
                warning = "新配置已保存，但旧密钥未能从 Keychain 清理；它已解除绑定，不会被此配置使用。"
            }
        }
        return SaveResult(settings: next, warning: warning)
    }
}
