import Foundation
import Security

/// A place photos are copied to: a local/mounted folder, or an SFTP server.
struct Destination: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case folder, sftp }

    var id = UUID()
    var name: String
    var kind: Kind
    var enabled = true

    // Folder
    var bookmark: Data?                 // security-scoped bookmark

    // SFTP (the password lives in the Keychain, never here)
    var host = ""
    var port = 22
    var username = ""
    var remotePath = ""
    var trustedHostKey: String?         // OpenSSH public key pinned on first connect (trust on first use)

    var key: String { id.uuidString }

    var summary: String {
        switch kind {
        case .folder: return "Folder"
        case .sftp: return "SFTP · \(username)@\(host):\(port) \(remotePath)"
        }
    }

    /// Existing single-folder installs become the first destination (keeps the ledger valid).
    static func migrateLegacy(defaults: UserDefaults) -> Destination? {
        guard let data = defaults.data(forKey: "destBookmark") else { return nil }
        let name = defaults.string(forKey: "destName") ?? "Folder"
        return Destination(name: name, kind: .folder, bookmark: data)
    }

    /// Only after the migrated destination list has been saved.
    static func clearLegacy(defaults: UserDefaults) {
        defaults.removeObject(forKey: "destBookmark")
        defaults.removeObject(forKey: "destName")
    }
}

enum Keychain {
    private static let service = "com.gc.PhotoSyncer.sftp"

    @discardableResult
    static func setPassword(_ password: String, account: String) -> OSStatus {
        delete(account: account)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(password.utf8),
        ]
        return SecItemAdd(attrs as CFDictionary, nil)
    }

    static func password(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
