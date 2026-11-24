import Foundation
import Security

/// What must not sit in plain files: each server's admin password and session
/// cookie. One keychain item per value, named after the server's id, so
/// removing a server removes exactly its own secrets.
struct SecretStore: Sendable {
    struct Failure: Error, Hashable {
        let status: OSStatus
    }

    var service: String = "com.jakezai.watchpost-pwvw"

    func value(for key: String) throws -> String? {
        var query = base(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores the text, or removes the entry when it is nil or empty.
    func set(_ text: String?, for key: String) throws {
        guard let text, !text.isEmpty else {
            try remove(key)
            return
        }
        let data = Data(text.utf8)
        let query = base(key)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw Failure(status: status) }
        } else if update != errSecSuccess {
            throw Failure(status: update)
        }
    }

    func remove(_ key: String) throws {
        let status = SecItemDelete(base(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    /// Every key that starts with `prefix`, for finding what a server left behind.
    func keys(withPrefix prefix: String) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(prefix) }
    }

    private func base(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
