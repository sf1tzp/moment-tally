import Foundation
import Security

/// Minimal wrapper over the Keychain Services C API for storing small secrets
/// (here: the Traggo device token). We deliberately store *only* the token —
/// never the user's password.
///
/// Note: when running an unsigned dev build from the terminal, macOS may prompt
/// once to allow keychain access. A signed, bundled build won't.
package enum Keychain {
    private static let service = "com.streetfortress.MomentTally"
    /// Pre-rename service identifiers, newest first: the PrimeTime era
    /// (#195), then the original traggo-menu-app era (#64). Items stored
    /// under either are migrated to `service` on first read and removed on
    /// write/delete, so tokens saved by older builds survive each rename
    /// without a re-login.
    private static let legacyServices = ["tools.primetime.PrimeTime",
                                         "lol.stev.traggo-menu-app"]

    package static func set(_ value: String, account: String) {
        let base = baseQuery(service: service, account: account)
        // Upsert: delete any existing item, then add fresh.
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
        // A fresh write supersedes any legacy copy; drop them so they can't
        // resurface later.
        for legacy in legacyServices {
            SecItemDelete(baseQuery(service: legacy, account: account) as CFDictionary)
        }
    }

    package static func get(account: String) -> String? {
        if let value = copy(service: service, account: account) {
            return value
        }
        // Miss under the current identifier: check the legacy ones (newest
        // first) and migrate the first hit.
        for legacy in legacyServices {
            if let value = copy(service: legacy, account: account) {
                set(value, account: account)
                return value
            }
        }
        return nil
    }

    package static func delete(account: String) {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        for legacy in legacyServices {
            SecItemDelete(baseQuery(service: legacy, account: account) as CFDictionary)
        }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func copy(service: String, account: String) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
