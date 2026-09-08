import Foundation
import CSQLite
import Darwin

// Tests inject failed commits and retained crash states through the same journal interface.
struct RedemptionStorage: Sendable {
    var load: @Sendable () throws -> [RedemptionRecord]
    var save: @Sendable (RedemptionRecord) throws -> Void

    static func disk(_ url: URL) -> Self {
        do {
            let database = try RedemptionDatabase(url: url)
            return Self(load: { try database.load() }, save: { try database.save($0) })
        } catch {
            return Self(load: { throw recoveryFault() }, save: { _ in throw recoveryFault() })
        }
    }
    static let unavailable = Self(load: { throw recoveryFault() }, save: { _ in throw recoveryFault() })
}

func recoveryFault() -> Fault {
    Fault("recovery_storage_unavailable", "Durable command storage is unavailable. No new consume is authorized; restore storage and restart Tally if needed.")
}

struct RedemptionJournal {
    private let storage: RedemptionStorage
    private var loaded = false
    private var uncommitted: [String: RedemptionRecord] = [:]
    private(set) var records: [String: RedemptionRecord] = [:]
    private(set) var error: Fault?

    init(storage: RedemptionStorage, now: Date) {
        self.storage = storage
        do {
            let rows = try storage.load()
            for row in rows {
                guard records[row.result.operationId] == nil else { throw recoveryFault() }
                records[row.result.operationId] = row
            }
            loaded = true
            for var record in rows where record.result.state == .pending {
                record.interrupt(at: now)
                records[record.result.operationId] = record
                try storage.save(record)
            }
        } catch {
            // Even if recovery cannot commit, cached pending records must never resume a spend.
            for key in records.keys where records[key]?.result.state == .pending { records[key]?.interrupt(at: now) }
            self.error = recoveryFault()
        }
    }

    mutating func save(_ record: RedemptionRecord) throws {
        guard loaded else { throw recoveryFault() }
        do { try storage.save(record) }
        catch { self.error = recoveryFault(); throw recoveryFault() }
        records[record.result.operationId] = record
        uncommitted[record.result.operationId] = nil
        error = nil
    }

    mutating func retainUncommitted(_ record: RedemptionRecord, at now: Date) {
        var candidate = record
        if candidate.result.state == .pending { candidate.interrupt(at: now) }
        uncommitted[record.result.operationId] = candidate
        var conservative = record
        conservative.interrupt(at: now)
        conservative.result.error = recoveryFault()
        records[record.result.operationId] = conservative
        error = recoveryFault()
    }

    mutating func retryResults() {
        // Retried local commits can retain a verdict already received in this process.
        // Startup only has durable records and never reconstructs a verdict from readings.
        for record in uncommitted.values.sorted(by: { $0.result.operationId < $1.result.operationId }) {
            do { try save(record) }
            catch { return }
        }
    }

    mutating func interruptPending(at now: Date) {
        for key in records.keys where records[key]?.result.state == .pending { records[key]?.interrupt(at: now) }
    }

    func block(accountID: String, target: IdentityEvidence?) -> RedemptionRecord? {
        records.values.filter { record in
            record.blocking && (record.result.accountId == accountID || target.map { record.target.relation(to: $0) != .different } == true)
        }.sorted { $0.result.operationId < $1.result.operationId }.first
    }
}

// The lock prevents two app owners from sending from independently cached journal states.
// SQLite EXTRA + fullfsync commits the rollback journal, database, and directory before returning.
private final class RedemptionDatabase: @unchecked Sendable {
    private let mutex = NSLock()
    private var database: OpaquePointer?
    private var lockFD: Int32 = -1
    private let path: String
    private var inode: UInt64 = 0

    init(url: URL) throws {
        path = url.path
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        lockFD = open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw recoveryFault() }
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw recoveryFault() }
        sqlite3_busy_timeout(database, 1000)
        try execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=EXTRA; PRAGMA fullfsync=ON; CREATE TABLE IF NOT EXISTS redemptions (id TEXT PRIMARY KEY NOT NULL, record BLOB NOT NULL);")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        // SQLite syncs its own directory entries. Also retain any newly created ancestor
        // directories before accepting the first command in a fresh app installation.
        var directory = url.deletingLastPathComponent().standardizedFileURL
        while true {
            let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY)
            guard descriptor >= 0 else { throw recoveryFault() }
            let synced = fsync(descriptor)
            close(descriptor)
            guard synced == 0 else { throw recoveryFault() }
            if directory.path == "/" { break }
            directory.deleteLastPathComponent()
        }
        inode = try fileInode()
    }

    deinit {
        if let database { sqlite3_close(database) }
        if lockFD >= 0 { close(lockFD) }
    }

    private func fileInode() throws -> UInt64 {
        guard let number = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber else { throw recoveryFault() }
        return number.uint64Value
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw recoveryFault() }
    }

    func load() throws -> [RedemptionRecord] {
        mutex.lock(); defer { mutex.unlock() }
        guard try fileInode() == inode else { throw recoveryFault() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT id, record FROM redemptions ORDER BY id", -1, &statement, nil) == SQLITE_OK else { throw recoveryFault() }
        defer { sqlite3_finalize(statement) }
        var records: [RedemptionRecord] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return records }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 1), let id = sqlite3_column_text(statement, 0) else { throw recoveryFault() }
            let record = try Wire.decoder().decode(RedemptionRecord.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1))))
            guard record.result.operationId == String(cString: id), try operationUUID(record.result.operationId) == record.result.operationId,
                  !record.maySend || record.result.selectedCreditId != nil else { throw recoveryFault() }
            records.append(record)
        }
    }

    func save(_ record: RedemptionRecord) throws {
        let data = try Wire.encoder().encode(record)
        mutex.lock(); defer { mutex.unlock() }
        guard try fileInode() == inode else { throw recoveryFault() }
        try execute("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "INSERT INTO redemptions(id, record) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET record=excluded.record", -1, &statement, nil) == SQLITE_OK else { throw recoveryFault() }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(statement, 1, record.result.operationId, -1, transient) == SQLITE_OK else { throw recoveryFault() }
            let bound = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), transient) }
            guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw recoveryFault() }
            try execute("COMMIT")
            guard try fileInode() == inode else { throw recoveryFault() }
        } catch {
            try? execute("ROLLBACK")
            throw recoveryFault()
        }
    }
}
