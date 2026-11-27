import Foundation
import PaperReaderKit

extension ReaderModel {
    public var fastModelSettings: ModelSettings { modelSettings.fastSettings }

    public var isModelReadyForRequests: Bool {
        guard (try? modelSettings.normalized()) != nil else { return false }
        return usesLocalModelKey(for: modelSettings) || hasConfiguredModelCredential
    }

    func usesLocalModelKey(for settings: ModelSettings) -> Bool {
        translationValidation?.key(for: settings) != nil
    }

    func modelKey(for settings: ModelSettings) async throws -> String {
        if let key = translationValidation?.key(for: settings) { return key }
        return try await configurationStore.keyForRequest(settings)
    }

    public func hasSavedAPIKey() async throws -> Bool {
        try await !configurationStore.keyForDraftRequest(modelSettings).isEmpty
    }

    public func refreshModelCredentialState() async {
        if usesLocalModelKey(for: modelSettings) {
            hasConfiguredModelCredential = true
            return
        }
        hasConfiguredModelCredential = (try? await hasSavedAPIKey()) == true
    }

    func updateModelCredentialReady(_ ready: Bool) {
        hasConfiguredModelCredential = usesLocalModelKey(for: modelSettings) || ready
    }

    public func testModelConnection(_ draft: ModelSettings, key: String, removeKey: Bool = false) async throws {
        let settings = try draft.normalized()
        let enteredKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let testKey: String
        if removeKey {
            testKey = ""
        } else if enteredKey.isEmpty, let localKey = translationValidation?.key(for: settings) {
            testKey = localKey
        } else if enteredKey.isEmpty {
            testKey = try await configurationStore.keyForDraftRequest(settings)
        } else {
            testKey = enteredKey
        }
        guard !testKey.isEmpty else { throw ReaderError.message("请填写当前 API 地址对应的密钥，再测试连接。") }
        try Task.checkCancellation()
        _ = try await client.complete(
            settings: settings, key: testKey,
            system: "这是 API 连通性测试。只回复 OK。",
            user: "请回复 OK，不要添加解释。")
        try Task.checkCancellation()
    }
}
