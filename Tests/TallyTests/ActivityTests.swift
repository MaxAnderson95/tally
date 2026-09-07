import Foundation
import Testing
import CSQLite
@testable import TallyCore

private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

@Test func activityCalendarCutoffAndDisjointCoverage() throws {
    let cutoff = instant("2026-03-09T16:00:00Z")
    let usage = Tokens(input: 1, output: 2, reasoning: 3, cacheRead: 4, cacheWrite: 5, total: 15)
    let scan = ActivityScan(databaseIdentity: "db", rows: [
        ActivityRow(created: instant("2026-03-08T05:00:00Z"), provider: "anthropic", model: "m", tokens: usage, cost: Decimal(string: "0.12")),
        ActivityRow(created: instant("2026-03-09T04:00:00Z"), provider: "opencode-go", model: "grok", tokens: usage, cost: 0),
        ActivityRow(created: instant("2026-03-09T05:00:00Z"), provider: "openai", model: "missing", tokens: nil, cost: nil),
        ActivityRow(created: cutoff, provider: "openai", model: "future", tokens: usage, cost: 999),
        ActivityRow(created: cutoff.addingTimeInterval(-1), provider: "opencode", model: "zen", tokens: usage, cost: 999)
    ])
    let views = scan.derive(namespace: "opaque", cutoff: cutoff, timezone: TimeZone(identifier: "America/New_York")!)
    let today = try #require(views["today"]), yesterday = try #require(views["yesterday"])
    #expect(today.totals.rows == 2 && today.totals.tokens?.total == 15 && today.totals.missingUsageRows == 1)
    #expect(today.totals.recordedCost.amount == "0" && today.totals.recordedCost.ambiguousZeroRows == 1)
    #expect(today.totals.estimate.status == "unpriced" && today.totals.estimate.lower == nil)
    #expect(today.totals.estimate.coverage.unpricedRows == 1 && today.totals.estimate.coverage.missingUsageRows == 1)
    #expect(today.totals.estimate.exclusions.first?.tokens == nil)
    #expect(yesterday.endAt.timeIntervalSince(yesterday.startAt) == 23 * 3600)
    #expect(yesterday.totals.recordedCost.amount == "0.12")
    for value in views.values {
        #expect(value.trend.days.count == 30 && value.trend.endAt == cutoff)
        #expect(value.trend.days.last?.endAt == cutoff)
        #expect(value.source.attribution == "provider_local_database" && value.source.partialHistory)
    }
    #expect(today.trend.days.filter(\.selected).count == 1)
    #expect(views["last30days"]?.trend.days.filter(\.selected).count == 30)
    #expect(views["last30days"]?.totals.tokens?.total == 30)
    let empty = today.trend.days[0].totals
    #expect(empty.rows == 0 && empty.tokens?.total == 0 && empty.estimate.status == "empty" && empty.estimate.lower == "0")
    #expect(empty.costLabel == "Recorded cost: no recorded activity")
    let missing = today.providers.first!.totals
    #expect(missing.tokens == nil && missing.recordedCost.amount == nil && missing.estimate.exclusions.first?.tokens == nil)
    let autumn = scan.derive(namespace: "opaque", cutoff: instant("2026-11-02T17:00:00Z"), timezone: TimeZone(identifier: "America/New_York")!)["yesterday"]!
    #expect(autumn.endAt.timeIntervalSince(autumn.startAt) == 25 * 3600)
    let zero = ActivityScan(databaseIdentity: "db", rows: [ActivityRow(created: cutoff.addingTimeInterval(-1), provider: "openai", model: "zero", tokens: Tokens(), cost: 0)])
        .derive(namespace: "opaque", cutoff: cutoff, timezone: .gmt)["today"]!.totals
    #expect(zero.rows == 1 && zero.tokens?.total == 0 && zero.estimate.status == "unpriced" && zero.estimate.lower == nil)
}

private struct ActivityDatabase {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var path: String { directory.appendingPathComponent("opencode.db").path }
    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try execute("""
        CREATE TABLE session_v2 (id TEXT PRIMARY KEY, parent_id TEXT, fork_session_id TEXT, fork_boundary TEXT, time_created INTEGER);
        CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, data TEXT);
        CREATE TABLE credential (id TEXT, label TEXT, value TEXT, integration_id TEXT, time_created INTEGER);
        INSERT INTO session_v2 VALUES ('parent',NULL,NULL,NULL,0), ('child','parent',NULL,NULL,0),
          ('fork',NULL,'parent','{"type":"after","messageID":"original"}',1000),
          ('orphan',NULL,'deleted',NULL,1000), ('nested',NULL,'fork','{"type":"before","messageID":"own"}',2000);
        """)
    }
    func execute(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw Fault("fixture", "Cannot open fixture") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Fault("fixture", String(cString: sqlite3_errmsg(db))) }
    }
    func add(_ id: String, session: String, seq: Int, time: Int, provider: String = "openai", usage: String = "{\"input\":1,\"output\":2,\"reasoning\":3,\"cache\":{\"read\":4,\"write\":5}}") throws {
        try execute("INSERT INTO session_message VALUES ('\(id)','\(session)','assistant',\(seq),\(time),'{\"model\":{\"providerID\":\"\(provider)\",\"id\":\"same-model\"},\"tokens\":\(usage),\"cost\":0}');")
    }
}

@Test func activityScannerRetainsRequestsExcludesForksAndReplacesMutableSource() throws {
    let db = try ActivityDatabase(); defer { try? FileManager.default.removeItem(at: db.directory) }
    try db.add("original", session: "parent", seq: 1, time: 1000)
    try db.add("copy-equal", session: "fork", seq: 1, time: 1000)
    try db.add("own", session: "fork", seq: 2, time: 1100)
    try db.add("orphan-copy", session: "orphan", seq: 1, time: 999)
    try db.add("nested-copy", session: "nested", seq: 1, time: 1000)
    try db.add("nested-own", session: "nested", seq: 3, time: 2100)
    try db.add("child-request", session: "child", seq: 1, time: 1000)
    try db.add("migrated-distinct", session: "parent", seq: 2, time: 1000)
    try db.add("go", session: "parent", seq: 3, time: 1000, provider: "opencode-go")
    try db.add("zen", session: "parent", seq: 4, time: 1000, provider: "opencode")
    try db.add("missing", session: "parent", seq: 5, time: 1000, usage: "null")
    try db.add("future", session: "parent", seq: 6, time: 3000)
    let reader = OpenCodeActivity(path: db.path), cutoff = Date(timeIntervalSince1970: 3)
    let first = try reader.read(cutoff: cutoff)
    #expect(first.rows.count == 7 && first.rows.compactMap(\.tokens).count == 6)
    #expect(first.rows.filter { $0.provider == "opencode-go" }.count == 1)
    #expect(try reader.read(cutoff: cutoff).rows.count == 7)
    try db.execute("DELETE FROM session_message WHERE id = 'own'")
    #expect(try reader.read(cutoff: cutoff).rows.count == 6)
    try db.execute("UPDATE session_message SET data = json_set(data, '$.tokens.input', 10) WHERE id = 'original'")
    #expect(try reader.read(cutoff: cutoff).rows.compactMap(\.tokens).map(\.input).contains(10))
    try db.execute("UPDATE session_message SET data = json_set(data, '$.tokens.output', -183) WHERE id = 'original'")
    #expect(try reader.read(cutoff: cutoff).rows.compactMap(\.tokens).map(\.output).contains(-183))
    try db.execute("UPDATE session_message SET data = replace(data, '\"cost\":0', '\"cost\":0.123456789123456789') WHERE id = 'original'")
    #expect(try reader.read(cutoff: cutoff).rows.compactMap(\.cost).contains(Decimal(string: "0.123456789123456789")!))
    try db.execute("DELETE FROM session_message")
    #expect(try reader.read(cutoff: cutoff).rows.isEmpty)
    try db.execute("ALTER TABLE session_message RENAME COLUMN seq TO incompatible")
    #expect(throws: Fault.self) { try reader.read(cutoff: cutoff) }
    #expect(throws: Fault.self) { try OpenCodeActivity(path: db.path + "missing").read(cutoff: cutoff) }
}

@Test func activityRemainsAvailableWhenCredentialSchemaFailsAndAccountsDisappear() async throws {
    let db = try ActivityDatabase(); defer { try? FileManager.default.removeItem(at: db.directory) }
    try db.add("retained", session: "parent", seq: 1, time: Int(Date().timeIntervalSince1970 * 1000) - 1000)
    try db.execute("INSERT INTO credential VALUES ('account','Account','{\"type\":\"key\",\"key\":\"fixture\"}','opencode-go',0)")
    let owner = TallyOwner(databasePath: db.path, appBuild: "test", storageURL: nil)
    try await owner.refresh(accountIDs: []); await owner.waitForCollection()
    #expect(await owner.snapshot().accounts.count == 1)
    #expect(await owner.activityResponse().activity.data?.totals.rows == 1)
    try db.execute("DELETE FROM credential")
    try await owner.refresh(accountIDs: []); await owner.waitForCollection()
    #expect(await owner.snapshot().accounts.isEmpty)
    #expect(await owner.activityResponse().activity.data?.totals.rows == 1)
    try db.execute("ALTER TABLE credential RENAME COLUMN value TO incompatible")
    do { try await owner.refresh(accountIDs: []); Issue.record("Expected inventory failure") } catch {}
    await owner.waitForCollection()
    #expect(await owner.snapshot().status.inventory.error != nil)
    #expect(await owner.activityResponse().activity.data?.totals.rows == 1)
    #expect(await owner.activityResponse().activity.stale == false)
}

private final class ActivityScenario: @unchecked Sendable {
    private let lock = NSLock()
    private var time = instant("2026-09-07T12:00:00Z")
    private var zone = TimeZone(identifier: "America/New_York")!
    private var failed = false
    private var identity = "db"
    private var calls = 0
    func now() -> Date { lock.withLock { time } }
    func timezone() -> TimeZone { lock.withLock { zone } }
    func count() -> Int { lock.withLock { calls } }
    func change(seconds: Double = 0, failed: Bool = false, zone: TimeZone? = nil, identity: String? = nil) {
        lock.withLock { time += seconds; self.failed = failed; if let zone { self.zone = zone }; if let identity { self.identity = identity } }
    }
    func inventory() -> InventoryRead { lock.withLock { InventoryRead(databaseIdentity: identity, credentials: []) } }
    func scan() throws -> ActivityScan {
        try lock.withLock {
            calls += 1
            if failed { throw Fault("activity_unavailable", "Synthetic source failure") }
            return ActivityScan(databaseIdentity: identity, rows: [ActivityRow(created: instant("2026-09-07T02:00:00Z"), provider: "openai", model: "m", tokens: Tokens(input: 1, total: 1), cost: 0)])
        }
    }
    func owner(storage: URL? = nil) -> TallyOwner {
        TallyOwner(clock: { self.now() }, storageURL: storage, inventory: { self.inventory() }, timezone: { self.timezone() }, scanActivity: { _ in try self.scan() }, collect: { _ in throw Fault("unexpected", "No Accounts") })
    }
}

@Test func activityRecoveryTimezoneNamespacesAndIndependentCadence() async throws {
    let scenario = ActivityScenario()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = directory.appendingPathComponent("cache.json")
    let owner = scenario.owner(storage: storage)
    try await owner.refresh(accountIDs: []); await owner.waitForCollection()
    #expect(await owner.activityResponse().activity.data?.totals.rows == 0)
    #expect(await owner.activityResponse(range: .yesterday).activity.data?.totals.rows == 1)
    await owner.tick(); await owner.waitForCollection(); #expect(scenario.count() == 1)
    scenario.change(seconds: 120, failed: true, zone: .gmt)
    await owner.tick(); await owner.waitForCollection()
    let stale = await owner.activityResponse().activity
    #expect(stale.stale && stale.data?.timezone == "America/New_York" && stale.error != nil)
    await owner.tick(); await owner.waitForCollection(); #expect(scenario.count() == 2)
    let restored = scenario.owner(storage: storage)
    try await restored.refresh(accountIDs: []); await restored.waitForCollection()
    #expect(await restored.activityResponse().activity.stale)
    #expect(await restored.activityResponse().activity.data?.timezone == "America/New_York")
    scenario.change()
    try await restored.refresh(accountIDs: []); await restored.waitForCollection()
    #expect(await restored.activityResponse().activity.data?.timezone == "GMT")
    #expect(await restored.activityResponse().activity.data?.totals.rows == 1)
    scenario.change(failed: true, identity: "another-db")
    try await restored.refresh(accountIDs: []); await restored.waitForCollection()
    #expect(await restored.activityResponse().activity.data == nil)
    scenario.change(failed: true, identity: "db")
    try await restored.refresh(accountIDs: []); await restored.waitForCollection()
    #expect(await restored.activityResponse().activity.data?.totals.rows == 1)
}

@Test func activityWireFixtureAndOptionalLiveSourceEvidence() async throws {
    let scenario = ActivityScenario()
    let owner = TallyOwner(clock: { scenario.now() }, inventory: { scenario.inventory() }, timezone: { scenario.timezone() }, scanActivity: { _ in
        var scan = try scenario.scan()
        scan.rows.append(ActivityRow(created: instant("2026-09-07T03:00:00Z"), provider: "anthropic", model: "usage-missing", tokens: nil, cost: nil))
        scan.rows.append(ActivityRow(created: instant("2026-09-07T04:00:00Z"), provider: "opencode-go", model: "recorded-zero", tokens: Tokens(), cost: 0))
        return scan
    }, collect: { _ in throw Fault("unexpected", "No Accounts") })
    try await owner.refresh(accountIDs: []); await owner.waitForCollection()
    let response = await owner.activityResponse(range: .last30days)
    if let output = ProcessInfo.processInfo.environment["TALLY_ACTIVITY_FIXTURE_OUTPUT"] {
        try Wire.encoder().encode(response).write(to: URL(fileURLWithPath: output))
        return
    }
    let data = try fixture("activity")
    let decoded = try Wire.decoder().decode(ActivityResponse.self, from: data)
    #expect(decoded.activity.data?.range == .last30days)
    #expect(decoded.activity.data?.trend.days.count == 30)
    #expect(decoded.activity.data?.totals.tokens?.input == 1)
    #expect(decoded.activity.data?.totals.estimate.lower == nil)
    #expect(decoded.activity.data?.totals.recordedCost.ambiguousZeroRows == 2)
    #expect(decoded.activity.data?.totals.missingUsageRows == 1)
    #expect(decoded.activity.data?.providers.first?.totals.tokens == nil)
    let original = try JSONSerialization.jsonObject(with: data) as! NSDictionary
    let roundTrip = try JSONSerialization.jsonObject(with: Wire.encoder().encode(decoded)) as! NSDictionary
    #expect(original == roundTrip)
    if let path = ProcessInfo.processInfo.environment["TALLY_ACTIVITY_LIVE_SOURCE"] {
        let cutoff = Date(), scan = try OpenCodeActivity(path: path).read(cutoff: cutoff)
        let views = scan.derive(namespace: "live-verification", cutoff: cutoff, timezone: .current)
        #expect(views.count == 3 && views.values.allSatisfy { $0.trend.days.count == 30 })
        print("Live activity scan: \(scan.rows.count) retained assistants; \(views["today"]!.totals.rows) today; 30 buckets per range; no credentials or conversation content selected.")
    }
}
