import Foundation
import PaperReaderKit

extension ReaderModel {
    func modelKey(for settings: ModelSettings) throws -> String { try configurationStore.key(for: settings) }

    public func hasSavedAPIKey() throws -> Bool { try !modelKey(for: modelSettings).isEmpty }

    public func testModelConnection(_ draft: ModelSettings, key: String, removeKey: Bool = false) async throws {
        let settings = try draft.normalized()
        let enteredKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let testKey = removeKey ? "" : (enteredKey.isEmpty ? try configurationStore.keyForDraft(settings) : enteredKey)
        guard !testKey.isEmpty else { throw ReaderError.message("请填写当前 API 地址对应的密钥，再测试连接。") }
        try Task.checkCancellation()
        _ = try await client.complete(
            settings: settings, key: testKey,
            system: "这是 API 连通性测试。只回复 OK。",
            user: "请回复 OK，不要添加解释。")
        try Task.checkCancellation()
    }
}
