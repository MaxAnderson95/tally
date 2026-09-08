import Foundation
import CSQLite
import CryptoKit

struct StoredCredential: Sendable {
    var storedID: String
    var name: String
    var key: String
    var provider = "opencode-go"
    var refresh: String? = nil
    var workspace: String? = nil
    var expiresAt: Date? = nil

    var fingerprint: String { identityDigest(key) }

    var evidence: IdentityEvidence {
        IdentityEvidence(provider: provider, workspace: workspace.map(identityDigest),
                         tokens: Set(([key] + [refresh].compactMap { $0 }).filter { !$0.isEmpty }.map(identityDigest)))
    }
}

func identityDigest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

struct InventoryRead: Sendable {
    var databaseIdentity: String
    var credentials: [StoredCredential]
}

public struct OpenCodeInventory: Sendable {
    public let path: String
    public init(path: String) { self.path = path }

    public static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        let root = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.local/share"
        let file = environment["OPENCODE_DB"] ?? "opencode.db"
        return file.hasPrefix("/") ? file : root + "/opencode/" + file
    }

    func databaseIdentity() throws -> String {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path) }
        catch { throw Fault("inventory_unavailable", "Cannot read the OpenCode database. Check its path in Tally settings.") }
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let created = attributes[.creationDate] as? Date else {
            throw Fault("inventory_unavailable", "Cannot identify the OpenCode database.")
        }
        return identityDigest("\(device):\(inode):\(created.timeIntervalSince1970)")
    }

    func read() throws -> InventoryRead {
        let identity = try databaseIdentity()
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw Fault("inventory_unavailable", "Cannot read the OpenCode database. Check its path in Tally settings.")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        var statement: OpaquePointer?
        // Selecting required columns validates their presence while accepting additive schema changes.
        let sql = "SELECT id, label, value, integration_id, time_created FROM credential WHERE integration_id IN ('anthropic', 'openai', 'opencode-go', 'xai') ORDER BY time_created, id"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Fault("inventory_schema_incompatible", "OpenCode's credential schema is not compatible with this Tally build.")
        }
        defer { sqlite3_finalize(statement) }
        struct KeyValue: Decodable { var key: String? }
        struct OAuthValue: Decodable { var access: String; var refresh: String; var expires: Double }
        struct WorkspaceValue: Decodable {
            var metadata: Metadata?
            struct Metadata: Decodable { var accountID: String? }
        }
        var credentials: [StoredCredential] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw Fault("inventory_unavailable", "OpenCode inventory could not be read completely.") }
            func text(_ column: Int32) throws -> String {
                guard sqlite3_column_type(statement, column) == SQLITE_TEXT, let bytes = sqlite3_column_text(statement, column) else {
                    throw Fault("inventory_schema_incompatible", "A required OpenCode credential field is invalid.")
                }
                return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
            }
            struct Kind: Decodable { var type: String }
            struct Method: Decodable { var methodID: String }
            let provider = try text(3)
            let data = Data(try text(2).utf8)
            let kind: Kind
            do { kind = try JSONDecoder().decode(Kind.self, from: data) }
            catch { throw Fault("inventory_schema_incompatible", "An OpenCode credential cannot be decoded.") }
            guard kind.type == (provider == "opencode-go" ? "key" : "oauth") else { continue }
            let methods = ["anthropic": ["claude-subscription"], "openai": ["chatgpt-browser", "chatgpt-headless"], "xai": ["device", "browser"]]
            if provider != "opencode-go" {
                let method: String
                do { method = try JSONDecoder().decode(Method.self, from: data).methodID }
                catch { throw Fault("inventory_schema_incompatible", "An OAuth credential has no valid authentication method.") }
                if !methods[provider, default: []].contains(method) { continue }
            }
            guard sqlite3_column_type(statement, 4) == SQLITE_INTEGER else {
                throw Fault("inventory_schema_incompatible", "An OpenCode credential creation time is invalid.")
            }
            let secret: String
            var refresh: String?
            var workspace: String?
            var expiresAt: Date?
            do {
                if provider == "opencode-go" {
                    guard let key = try JSONDecoder().decode(KeyValue.self, from: data).key,
                          !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else { continue }
                    secret = key
                }
                else {
                    let value = try JSONDecoder().decode(OAuthValue.self, from: data)
                    guard value.expires.isFinite, value.expires >= 0 else { throw Fault("inventory_schema_incompatible", "Invalid OAuth expiry.") }
                    secret = value.access; refresh = value.refresh
                    expiresAt = Date(timeIntervalSince1970: value.expires / 1000)
                    if provider == "openai" { workspace = try JSONDecoder().decode(WorkspaceValue.self, from: data).metadata?.accountID }
                }
            } catch { throw Fault("inventory_schema_incompatible", "An OpenCode credential cannot be decoded.") }
            guard !secret.isEmpty, !secret.contains(where: { $0.isWhitespace }) else {
                throw Fault("credentials_unavailable", "A stored credential is invalid. Manage this Account in OpenCode.")
            }
            let credential = StoredCredential(storedID: try text(0), name: try text(1), key: secret, provider: provider,
                                              refresh: refresh, workspace: workspace.flatMap { $0.isEmpty ? nil : $0 }, expiresAt: expiresAt)
            if !credentials.contains(where: { $0.evidence.relation(to: credential.evidence) == .same }) { credentials.append(credential) }
        }
        guard try databaseIdentity() == identity else { throw Fault("inventory_unavailable", "OpenCode database changed during the read.") }
        return InventoryRead(databaseIdentity: identity, credentials: credentials)
    }
}
