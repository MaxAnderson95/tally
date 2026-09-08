import Foundation
import CSQLite

struct GoCredential: Sendable {
    var storedID: String
    var name: String
    var key: String
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

    func read() throws -> [GoCredential] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw Fault("inventory_unavailable", "Cannot read the OpenCode database. Check its path in Tally settings.")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        var statement: OpaquePointer?
        // Selecting required columns validates their presence while accepting additive schema changes.
        let sql = "SELECT id, label, value FROM credential WHERE integration_id = 'opencode-go' ORDER BY time_created, id"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Fault("inventory_schema_incompatible", "OpenCode's credential schema is not compatible with this Tally build.")
        }
        defer { sqlite3_finalize(statement) }
        struct Value: Decodable { var type: String; var key: String? }
        var keys = Set<String>()
        var credentials: [GoCredential] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw Fault("inventory_unavailable", "OpenCode inventory could not be read completely.") }
            func text(_ column: Int32) throws -> String {
                guard sqlite3_column_type(statement, column) == SQLITE_TEXT, let bytes = sqlite3_column_text(statement, column) else {
                    throw Fault("inventory_schema_incompatible", "A required OpenCode credential field is invalid.")
                }
                return String(cString: bytes)
            }
            let value: Value
            do { value = try JSONDecoder().decode(Value.self, from: Data(try text(2).utf8)) }
            catch { throw Fault("inventory_schema_incompatible", "An OpenCode Go credential cannot be decoded.") }
            guard value.type == "key" else { continue }
            guard let key = value.key, !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else {
                continue
            }
            if keys.insert(key).inserted {
                credentials.append(GoCredential(storedID: try text(0), name: try text(1), key: key))
            }
        }
        return credentials
    }
}
