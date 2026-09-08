import Foundation
import CSQLite

struct OpenCodeActivity: Sendable {
    var path: String

    func scan(cutoff: Date) async throws -> ActivityScan {
        let task = Task.detached { try read(cutoff: cutoff) }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            task.cancel()
        }
    }

    func read(cutoff: Date) throws -> ActivityScan {
        let source = OpenCodeInventory(path: path)
        let identity = try source.databaseIdentity()
        let invalid = Fault("activity_schema_incompatible", "OpenCode's assistant activity schema is not compatible with this Tally build.")
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw Fault("activity_unavailable", "Cannot read OpenCode activity. Check the database path in Settings.")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        // One statement is one SQLite snapshot. Select no conversation content or credentials.
        // A surviving lineage boundary also identifies same-millisecond copies; timestamps cover deleted ancestors.
        let sql = """
        SELECT m.time_created, json_extract(m.data, '$.model.providerID'), json_extract(m.data, '$.model.id'),
               json_extract(m.data, '$.tokens'), m.data -> '$.cost', json_type(m.data, '$.cost')
        FROM session_message m JOIN session_v2 s ON s.id = m.session_id
        WHERE m.type = 'assistant' AND m.time_created < ?
          AND json_extract(m.data, '$.model.providerID') IN ('anthropic', 'openai', 'opencode-go', 'xai')
          AND (s.fork_session_id IS NULL OR (
            m.time_created >= s.time_created AND NOT EXISTS (
              SELECT 1 FROM session_message b
              WHERE b.session_id = s.fork_session_id AND b.id = json_extract(s.fork_boundary, '$.messageID')
                AND ((json_extract(s.fork_boundary, '$.type') = 'before' AND m.seq < b.seq)
                  OR (json_extract(s.fork_boundary, '$.type') = 'through' AND m.seq <= b.seq))
            )
          ))
        ORDER BY m.time_created, m.id
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw invalid }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970 * 1000)
        struct Usage: Decodable {
            var input: Double; var output: Double; var reasoning: Double; var cache: Cache
            struct Cache: Decodable { var read: Double; var write: Double }
        }
        var rows: [ActivityRow] = []
        var tokenSum = Tokens()
        var costSum = Decimal.zero
        while true {
            if Task.isCancelled { throw CancellationError() }
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw Fault("activity_unavailable", "OpenCode activity could not be read completely.") }
            func text(_ index: Int32) -> String? {
                guard sqlite3_column_type(statement, index) == SQLITE_TEXT, let bytes = sqlite3_column_text(statement, index) else { return nil }
                return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
            }
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER, let provider = text(1), let model = text(2), !model.isEmpty else { throw invalid }
            var tokens: Tokens?
            if sqlite3_column_type(statement, 3) != SQLITE_NULL {
                guard let data = text(3), let usage = try? JSONDecoder().decode(Usage.self, from: Data(data.utf8)),
                      [usage.input, usage.output, usage.reasoning, usage.cache.read, usage.cache.write].allSatisfy(\.isFinite) else { throw invalid }
                tokens = Tokens(input: usage.input, output: usage.output, reasoning: usage.reasoning, cacheRead: usage.cache.read, cacheWrite: usage.cache.write,
                                total: usage.input + usage.output + usage.reasoning + usage.cache.read + usage.cache.write)
                guard tokens!.total.isFinite else { throw invalid }
                tokenSum.add(tokens!)
                guard tokenSum.total.isFinite else { throw invalid }
            }
            var cost: Decimal?
            if let kind = text(5), kind != "null" {
                guard ["integer", "real"].contains(kind), let value = text(4), let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), !amount.isNaN else { throw invalid }
                cost = amount
                costSum += amount
                guard !costSum.isNaN else { throw invalid }
            }
            rows.append(ActivityRow(created: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0)) / 1000), provider: provider, model: model, tokens: tokens, cost: cost))
        }
        guard try source.databaseIdentity() == identity else { throw Fault("activity_unavailable", "OpenCode database changed during the activity scan.") }
        return ActivityScan(databaseIdentity: identity, rows: rows)
    }
}
