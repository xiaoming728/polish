import Foundation
import Security

// 仅测 data protection keychain 在 ad-hoc 签名、无 entitlement 下的行为。成功则立即删除。
let q: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.example.polish.research-probe",
    kSecAttrAccount as String: "probe",
    kSecValueData as String: Data("x".utf8),
    kSecUseDataProtectionKeychain as String: true,
    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
]
let s = SecItemAdd(q as CFDictionary, nil)
print("SecItemAdd(dataProtection) status:", s, SecCopyErrorMessageString(s, nil) as String? ?? "")
if s == errSecSuccess {
    var d = q; d[kSecValueData as String] = nil
    print("cleanup:", SecItemDelete(d as CFDictionary))
}
