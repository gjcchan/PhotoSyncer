import Foundation
import Security

/// A place photos are copied to: a local/mounted folder, an SFTP server, or an SMB share.
nonisolated struct Destination: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case folder, sftp, smb }

    static let defaultSMBPort = 445

    var id = UUID()
    var name: String
    var kind: Kind
    var enabled = true

    // Folder
    var bookmark: Data?                 // security-scoped bookmark

    // SFTP / SMB (the password lives in the Keychain, never here)
    var host = ""
    var port = 22
    var username = ""
    var remotePath = ""                 // SFTP: folder on the server. SMB: folder inside the share ("" = share root)
    // New fields stay optional so destinations saved by older versions still decode.
    var share: String?                  // SMB share name
    var guest: Bool?                    // SMB: connect without credentials
    var trustedHostKey: String?         // OpenSSH public key pinned on first connect (trust on first use)

    var key: String { id.uuidString }

    var summary: String {
        switch kind {
        case .folder: return "Folder"
        case .sftp: return "SFTP · \(username)@\(host):\(port) \(remotePath)"
        case .smb:
            let who = guest == true ? "guest" : username
            let p = port == Self.defaultSMBPort ? "" : ":\(port)"
            let sub = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/\\ ")).isEmpty ? "" : "/\(remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/\\ ")))"
            return "SMB · \(who)@\(host)\(p)/\(share ?? "")\(sub)"
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
