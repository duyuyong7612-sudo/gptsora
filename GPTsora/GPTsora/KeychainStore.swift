// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-02d1759cedc58ac22ca29c5e3af81edb8e2c1d2b5f515678709298e155c4c4e5"
// Source-SHA256: "cf32c1d81b425d196d0282b9f29a7f9b3d2cdeb331e8a13672245342b232cc65"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Security

enum KeychainStore {

    private static let service = "com.solara.gptsora"
    private static let account = "access_token"

    // MARK: - Save

    static func saveToken(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }

        DispatchQueue.global(qos: .utility).async {
            let qDel: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(qDel as CFDictionary)

            let qAdd: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessible as String:
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            SecItemAdd(qAdd as CFDictionary, nil)
        }
    }

    // MARK: - Load

    static func loadToken(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: AnyObject?
            let status = SecItemCopyMatching(q as CFDictionary, &item)

            guard status == errSecSuccess,
                  let data = item as? Data,
                  let token = String(data: data, encoding: .utf8),
                  !token.isEmpty else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            DispatchQueue.main.async {
                completion(token)
            }
        }
    }

    // MARK: - Clear

    static func clearToken() {
        DispatchQueue.global(qos: .utility).async {
            let qDel: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(qDel as CFDictionary)
        }
    }
}

