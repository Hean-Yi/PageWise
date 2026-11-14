import Foundation
import Testing

@testable import PaperReaderKit

@MainActor private final class MemoryCredentials: ModelCredentialStore {
    var values = ["model-key": "legacy-test-only"]
    var rejectWrites = false
    var rejectDeletes = false
    func load(account: String) -> String { values[account] ?? "" }
    func save(_ value: String, account: String) throws {
        if (rejectWrites && !value.isEmpty) || (rejectDeletes && value.isEmpty) {
            throw ReaderError.message("Fake credential error")
        }
        values[account] = value.isEmpty ? nil : value
    }
}

@Test func modelSettingsNormalizeBaseOrCompleteEndpoint() throws {
    for url in [" https://EXAMPLE.invalid:443/v1/ ", "https://example.invalid/v1/chat/completions/"] {
        var settings = ModelSettings()
        settings.baseURL = url
        settings.model = " custom-model "
        let normalized = try settings.normalized()
        #expect(normalized.baseURL == "https://example.invalid/v1")
        #expect(normalized.model == "custom-model")
        #expect(try normalized.endpointURL().absoluteString == "https://example.invalid/v1/chat/completions")
    }
}

@Test func modelSettingsRejectInvalidDestinationsAndMissingModel() throws {
    for url in [
        "", "http://example.invalid/v1", "https://example.invalid/v1?key=secret",
        "https://user:secret@example.invalid/v1", "https://example.invalid/#secret", "https://example.invalid/a b",
    ] {
        var settings = ModelSettings()
        settings.baseURL = url
        settings.model = "test"
        #expect(throws: (any Error).self) { try settings.normalized() }
    }
    #expect(throws: (any Error).self) { try ModelSettings().normalized() }
}

@Test @MainActor func configurationMigratesLegacyAndDoesNotReuseKeyForChangedAddress() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"baseURL":"https://open.bigmodel.cn/api/paas/v4","model":"old","temperature":0.2}"#.utf8)
        .write(to: root.appendingPathComponent("model-settings.json"))
    let credentials = MemoryCredentials()
    let store = ModelConfigurationStore(directory: root, credentials: credentials)
    var draft = try store.load()
    #expect(try store.key(for: draft) == "legacy-test-only")
    draft.baseURL = "https://example.invalid/v1"
    #expect(try store.keyForDraft(draft).isEmpty)
    let result = try store.save(draft, key: nil)
    #expect(result.settings.credentialID != nil)
    #expect(try store.key(for: result.settings).isEmpty)
    #expect(credentials.values.isEmpty)
}

@Test @MainActor func configurationReplacesRetainsAndRemovesCredentials() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let credentials = MemoryCredentials()
    let store = ModelConfigurationStore(directory: root, credentials: credentials)
    var draft = ModelSettings()
    draft.model = "test"
    let saved = try store.save(draft, key: "replacement-only")
    #expect(try store.key(for: saved.settings) == "replacement-only")
    #expect(credentials.values.count == 1)
    let retained = try store.save(saved.settings, key: "")
    #expect(retained.settings.credentialID == saved.settings.credentialID)
    let cleared = try store.save(retained.settings, key: nil, removeKey: true)
    #expect(try store.key(for: cleared.settings).isEmpty)
    #expect(credentials.values.isEmpty)
}

@Test @MainActor func keychainFailureDoesNotPublishSettingsAndCleanupFailureIsVisible() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let credentials = MemoryCredentials()
    let store = ModelConfigurationStore(directory: root, credentials: credentials)
    var draft = ModelSettings()
    draft.model = "test"
    credentials.rejectWrites = true
    #expect(throws: (any Error).self) { try store.save(draft, key: "replacement-only") }
    #expect(try store.load().model.isEmpty)
    credentials.rejectWrites = false
    credentials.rejectDeletes = true
    let saved = try store.save(draft, key: "replacement-only")
    #expect(saved.warning != nil)
    #expect(try store.key(for: saved.settings) == "replacement-only")
}

@Test @MainActor func configurationCanRemoveLegacyKeyWithoutModelName() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("model-settings.json")
    try Data(#"{"baseURL":"https://open.bigmodel.cn/api/paas/v4","model":"","temperature":0.2}"#.utf8)
        .write(to: file)
    let credentials = MemoryCredentials()
    let store = ModelConfigurationStore(directory: root, credentials: credentials)
    let previous = try store.load()
    #expect(previous.credentialID == nil)
    let cleared = try store.save(previous, key: nil, removeKey: true)
    #expect(cleared.settings.model.isEmpty)
    #expect(cleared.settings.baseURL == previous.baseURL)
    #expect(cleared.settings.credentialID != nil)
    #expect(try store.key(for: cleared.settings).isEmpty)
    #expect(credentials.values.isEmpty)
    #expect(try store.load() == cleared.settings)
}

@Test @MainActor func credentialRemovalDoesNotBypassValidationForOtherChanges() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let credentials = MemoryCredentials()
    let store = ModelConfigurationStore(directory: root, credentials: credentials)
    var draft = try store.load()
    draft.baseURL = "http://example.invalid/v1"
    draft.model = "test"
    #expect(throws: (any Error).self) { try store.save(draft, key: nil, removeKey: true) }
    #expect(try store.load() == ModelSettings())
    #expect(credentials.values == ["model-key": "legacy-test-only"])
}

@Test @MainActor func configurationReportsFailureToCleanUncommittedKey() throws {
    // The missing parent directory makes the settings write fail after the Keychain write.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let credentials = MemoryCredentials()
    credentials.rejectDeletes = true
    let store = ModelConfigurationStore(directory: root, credentials: credentials)
    let previous = try store.load()
    var draft = previous
    draft.model = "test"
    do {
        _ = try store.save(draft, key: "uncommitted-test-only")
        Issue.record("Expected the settings write to fail")
    } catch {
        #expect(error.localizedDescription.contains("临时 Keychain 项未能清理"))
        #expect(!error.localizedDescription.contains("uncommitted-test-only"))
    }
    #expect(try store.load() == previous)
    #expect(try store.key(for: previous) == "legacy-test-only")
    #expect(credentials.values.count == 2)
}
