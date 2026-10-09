import Foundation
import Security
import TallyCore

/// The web password and API token. Tally launches from Finder and login items without a shell environment, so it keeps
/// them in the login Keychain under the environment-variable names its clients use. An empty value removes the item.
struct ServeSecrets {
    static let password = "TALLY_SERVE_PASSWORD"
    static let token = "TALLY_SERVE_TOKEN"

    var read: (String) -> String
    var write: (String, String) throws -> Void

    static var keychain: ServeSecrets { ServeSecrets(read: { name in
        var item: CFTypeRef?
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }, write: { name, value in
        let match: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name]
        let deleted = SecItemDelete(match as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw Fault("keychain_unavailable", "Cannot update \(name) in the Keychain.") }
        guard !value.isEmpty else { return }
        var add = match
        add[kSecValueData] = Data(value.utf8)
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw Fault("keychain_unavailable", "Cannot save \(name) to the Keychain.") }
    }) }

    private static let service = "net.maxanderson.tally"
}
