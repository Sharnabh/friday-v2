import Foundation
import Security
import LocalAuthentication

public enum SpeechCredential {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.friday.assistant.openrouter",
         kSecAttrAccount as String: "speech"]
    }

    public static func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var value: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess,
              let bytes = value as? Data else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    public static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: OSStatus
        if key.isEmpty {
            result = SecItemDelete(query as CFDictionary)
            if result == errSecItemNotFound { return }
        } else {
            let attributes = [kSecValueData as String: Data(key.utf8)]
            result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if result == errSecItemNotFound {
                var item = query.merging(attributes) { _, new in new }
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                result = SecItemAdd(item as CFDictionary, nil)
            }
        }
        guard result == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
        }
    }
}
