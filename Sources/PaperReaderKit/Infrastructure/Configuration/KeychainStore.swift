import Foundation
import Security

public enum KeychainStore {
    private static let service = "dev.paperreader.api"
    public static func load(account: String = "model-key") throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8)
        else {
            throw ReaderError.message("无法读取钥匙串（\(status)）。")
        }
        return value
    }
    public static func save(_ value: String, account: String = "model-key") throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        if value.isEmpty {
            let result = SecItemDelete(query as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { throw ReaderError.message("无法删除密钥。") }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            for (attribute, value) in attributes { insert[attribute] = value }
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
                throw ReaderError.message("无法保存到钥匙串。")
            }
        } else if status != errSecSuccess {
            throw ReaderError.message("无法更新钥匙串（\(status)）。")
        }
    }
}
