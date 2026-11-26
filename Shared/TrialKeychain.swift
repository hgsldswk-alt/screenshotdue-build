import Foundation
import Security

enum TrialKeychain {
    static func firstOpen(now: Date) throws -> Date {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Launch.appGroup,
            kSecAttrAccount as String: "trial-start"
        ]
        var create = query
        create[kSecValueData as String] = try JSONEncoder().encode(now)
        create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(create as CFDictionary, nil)
        if add == errSecSuccess { return now }
        guard add == errSecDuplicateItem else { throw StorageError.unavailable }

        var read = query
        read[kSecReturnData as String] = true
        var value: CFTypeRef?
        guard SecItemCopyMatching(read as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { throw StorageError.unavailable }
        return try JSONDecoder().decode(Date.self, from: data)
    }
}
