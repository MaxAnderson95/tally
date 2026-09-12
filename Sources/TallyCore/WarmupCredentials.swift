import Foundation
import CSQLite

struct WarmupCredentials: Sendable {
    var transport: @Sendable (URLRequest) async throws -> ResetHTTPResponse = { try await SingleSendHTTP.send($0) }

    func refresh(_ credential: StoredCredential, now: Date) async throws -> StoredCredential {
        let endpoints = ["anthropic": "https://platform.claude.com/v1/oauth/token", "openai": "https://auth.openai.com/oauth/token", "xai": "https://auth.x.ai/oauth2/token"]
        let clients = ["anthropic": "9d1c250a-e61b-44d9-88ed-5944d1962f5e", "openai": "app_EMoamEEZ73f0CkXaXp7hrann", "xai": "b1a00492-073a-47ea-816f-4c329264a828"]
        guard let endpoint = endpoints[credential.provider], let client = clients[credential.provider], let refresh = credential.refresh, !refresh.isEmpty else {
            throw Fault("warmup_refresh", "This Account has no usable refresh token. Sign in again in OpenCode.")
        }
        let body = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": client]
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        if credential.provider == "anthropic" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        } else {
            var form = URLComponents()
            form.queryItems = body.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(form.percentEncodedQuery!.replacingOccurrences(of: "+", with: "%2B").utf8)
        }
        let response = try await transport(request)
        guard response.status == 200 else { throw Fault("warmup_refresh", "Token refresh failed (HTTP \(response.status)).") }
        struct Tokens: Decodable { var access_token: String; var refresh_token: String?; var expires_in: Double }
        let tokens = try JSONDecoder().decode(Tokens.self, from: response.body)
        guard !tokens.access_token.isEmpty, tokens.expires_in.isFinite, tokens.expires_in > 0,
              tokens.refresh_token.map({ !$0.isEmpty }) ?? true else { throw Fault("warmup_refresh", "Provider returned invalid refreshed credentials.") }
        var result = credential
        result.key = tokens.access_token; result.refresh = tokens.refresh_token ?? refresh
        result.expiresAt = now.addingTimeInterval(tokens.expires_in)
        return result
    }

    static func persist(_ refreshed: StoredCredential, replacing original: StoredCredential, path: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw Fault("warmup_refresh_storage", "Cannot save refreshed credentials to OpenCode.")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "UPDATE credential SET value = json_set(value, '$.access', ?, '$.refresh', ?, '$.expires', ?), time_updated = ? WHERE id = ? AND integration_id = ? AND json_extract(value, '$.access') = ? AND json_extract(value, '$.refresh') = ?"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw Fault("warmup_refresh_storage", "OpenCode credential schema changed.") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, text) in [(1, refreshed.key), (2, refreshed.refresh ?? ""), (5, original.storedID), (6, original.provider), (7, original.key), (8, original.refresh ?? "")] {
            sqlite3_bind_text(statement, Int32(index), text, -1, transient)
        }
        sqlite3_bind_double(statement, 3, refreshed.expiresAt!.timeIntervalSince1970 * 1000)
        sqlite3_bind_int64(statement, 4, Int64(Date().timeIntervalSince1970 * 1000))
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
            throw Fault("warmup_refresh_raced", "Account credentials changed during refresh.")
        }
    }
}
