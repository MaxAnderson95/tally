import Foundation
import Testing
import CSQLite
@testable import TallyCore

func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!)
}

@Test func decodesSharedWireFixture() throws {
    let refresh = try Wire.decoder().decode(RefreshResponse.self, from: fixture("refresh"))
    #expect(refresh.accounts.map { $0.schedule.state } == ["started", "joined", "deferred", "blocked"])
    #expect(refresh.accounts[2].schedule.nextAttemptAt == refresh.accounts[2].schedule.reason?.retryAt)
    #expect(refresh.activity.state == "started")
    let response = try Wire.decoder().decode(AccountsResponse.self, from: fixture("accounts"))
    #expect(response.accounts[0].pin.lines.count == 2)
    #expect(response.accounts[0].groups.quotas.data?.windows[1].remainingPercent == nil)
    #expect(response.accounts[0].groups.quotas.data?.windows[2].usedPercent == 0)
    #expect(response.accounts[0].groups.quotas.stale)
    #expect(response.accounts[0].groups.quotas.error?.code == "provider_unavailable")
}

@Test func mapsGoWithoutInventingTiming() throws {
    let valid = try GoUsage.decode(fixture("go-valid"))
    #expect(valid.windows.map(\.durationSeconds) == [18_000, 604_800, nil])
    #expect(valid.windows[0].usedPercent == 12.5)
    #expect(valid.windows[0].resetAt != nil)
    #expect(try GoUsage.decode(fixture("go-absent")).windows.isEmpty)
    #expect(throws: Fault.self) { try GoUsage.decode(fixture("go-malformed")) }
    #expect(throws: Fault.self) { try GoUsage.decode(Data(#"{"usage":{"rolling":{"status":"error","percent":10}}}"#.utf8)) }
    var unknown = try GoUsage.decode(fixture("go-unknown")).windows
    for index in unknown.indices { unknown[index].derive(at: Date(), groupStale: false) }
    #expect(unknown[0].remainingPercent == 100)
    #expect(unknown[0].resetState == "unknown")
    #expect(unknown[1].remainingPercent == nil)
    #expect(unknown[2].durationSeconds == nil)
}

@Test func discoversReadOnlyGoInventory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("opencode.db").path
    var db: OpaquePointer?
    #expect(sqlite3_open(path, &db) == SQLITE_OK)
    let sql = """
    CREATE TABLE credential (id TEXT, integration_id TEXT, label TEXT, value TEXT, active INTEGER, time_created INTEGER, additional TEXT);
    INSERT INTO credential VALUES ('zen', 'opencode', 'Zen first', '{"type":"key","key":"key-a"}', 1, 0, NULL);
    INSERT INTO credential VALUES ('a', 'opencode-go', 'Go Personal', '{"type":"key","key":"key-a"}', 0, 1, NULL);
    INSERT INTO credential VALUES ('b', 'opencode-go', 'WORK', '{"type":"key","key":"key-b"}', 1, 2, NULL);
    INSERT INTO credential VALUES ('c', 'opencode-go', 'Duplicate', '{"type":"key","key":"key-a"}', 1, 3, NULL);
    INSERT INTO credential VALUES ('d', 'opencode-go', 'Unsupported', '{"type":"oauth"}', 0, 4, NULL);
    INSERT INTO credential VALUES ('invalid-e', 'opencode-go', 'Whitespace key', '{"type":"key","key":"bad key"}', 0, 5, NULL);
    INSERT INTO credential VALUES ('invalid-f', 'opencode-go', 'Empty key', '{"type":"key","key":""}', 0, 6, NULL);
    INSERT INTO credential VALUES ('invalid-g', 'opencode-go', 'Missing key', '{"type":"key"}', 0, 7, NULL);
    INSERT INTO credential VALUES ('e', 'anthropic', 'Claude', '{"type":"oauth","methodID":"claude-subscription","access":"claude-a","refresh":"claude-r","expires":0,"metadata":{"accountID":42},"key":42}', 0, 5, NULL);
    INSERT INTO credential VALUES ('f', 'openai', 'Workspace A', '{"type":"oauth","methodID":"chatgpt-browser","access":"shared","refresh":"r","expires":0,"metadata":{"accountID":"workspace-a","addition":true}}', 0, 6, NULL);
    INSERT INTO credential VALUES ('g', 'openai', 'Workspace B', '{"type":"oauth","methodID":"chatgpt-browser","access":"shared","refresh":"r","expires":0,"metadata":{"accountID":"workspace-b"}}', 1, 7, NULL);
    INSERT INTO credential VALUES ('h', 'openai', 'Duplicate workspace', '{"type":"oauth","methodID":"chatgpt-headless","access":"other","refresh":"other-r","expires":0,"metadata":{"accountID":"workspace-a"}}', 1, 8, NULL);
    INSERT INTO credential VALUES ('i', 'xai', 'Grok', '{"type":"oauth","methodID":"device","access":"grok-a","refresh":"grok-r","expires":0}', 0, 9, NULL);
    INSERT INTO credential VALUES ('j', 'anthropic', 'API', '{"type":"key","key":"api-key"}', 1, 10, NULL);
    INSERT INTO credential VALUES ('k', 'openai', 'Unsupported method', '{"type":"oauth","methodID":"other"}', 1, 11, NULL);
    INSERT INTO credential VALUES ('l', 'mcp', 'MCP', 'invalid', 1, 12, NULL);
    """
    #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let before = try Data(contentsOf: URL(fileURLWithPath: path))
    let credentials = try OpenCodeInventory(path: path).read().credentials
    #expect(credentials.map(\.name) == ["Go Personal", "WORK", "Claude", "Workspace A", "Workspace B", "Grok"])
    #expect(credentials.prefix(2).map(\.key) == ["key-a", "key-b"])
    #expect(credentials[2].expiresAt == Date(timeIntervalSince1970: 0))
    #expect(credentials[0].expiresAt == nil)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
    #expect(throws: Fault.self) { try OpenCodeInventory(path: path + "-missing").read() }
    #expect(!FileManager.default.fileExists(atPath: path + "-missing"))
    #expect(OpenCodeInventory.defaultPath(environment: ["XDG_DATA_HOME": "/data", "OPENCODE_DB": "custom.db"], home: "/home") == "/data/opencode/custom.db")
    #expect(OpenCodeInventory.defaultPath(environment: ["OPENCODE_DB": "/custom.db"], home: "/home") == "/custom.db")
}

private final class Scenario: @unchecked Sendable {
    private let lock = NSLock()
    private var currentTime = Date(timeIntervalSince1970: 1_915_017_600)
    private var failed = false
    private var calls = 0
    func now() -> Date { lock.withLock { currentTime } }
    func advanceAndFail() { lock.withLock { currentTime += 20; failed = true } }
    func fetch() throws -> GoObservation {
        let failed = lock.withLock { calls += 1; return self.failed }
        if failed { throw Fault("provider_unavailable", "Sanitized provider failure.") }
        return try GoUsage.decode(fixture("go-valid"))
    }
    func count() -> Int { lock.withLock { calls } }
}

@Test func cachedReadsFailureAndRefreshContract() async throws {
    let scenario = Scenario()
    let owner = TallyOwner(clock: { scenario.now() }, inventory: {
        InventoryRead(databaseIdentity: "test-db", credentials: [StoredCredential(storedID: "cred-secret", name: "Fixture Go", key: "test-secret")])
    }, collect: { _ in try scenario.fetch() })
    #expect(await owner.snapshot().accounts.isEmpty)
    #expect(scenario.count() == 0)
    let refresh = try await owner.refresh()
    #expect(refresh.accounts.first?.schedule.state == "started")
    await owner.waitForCollection()
    let first = await owner.snapshot()
    #expect(first.accounts[0].groups.quotas.data?.windows[0].remainingPercent == 87.5)
    #expect(first.accounts[0].groups.plan.data?.name == "Go")
    #expect(first.accounts[0].groups.extraUsage.observedAt != nil)
    #expect(first.accounts[0].groups.extraUsage.data == nil)
    let wire = try Wire.encoder().encode(first)
    #expect(!String(decoding: wire, as: UTF8.self).contains("test-secret"))
    #expect(!String(decoding: wire, as: UTF8.self).contains("cred-secret"))
    #expect(try Wire.decoder().decode(AccountsResponse.self, from: wire).accounts.count == 1)
    #expect(try Wire.decoder().decode(AccountsResponse.self, from: wire).accounts[0].groups.quotas.data?.windows[0].resetAt == first.accounts[0].groups.quotas.data?.windows[0].resetAt)
    let object = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
    let account = try #require((object["accounts"] as? [[String: Any]])?.first)
    let groups = try #require(account["groups"] as? [String: [String: Any]])
    #expect(groups["extraUsage"]?["data"] is NSNull)
    #expect(groups["quotas"]?["error"] is NSNull)
    _ = await owner.snapshot(); _ = try await owner.account(id: first.accounts[0].id)
    #expect(scenario.count() == 1)
    #expect(try await owner.refresh().accounts[0].schedule.state == "deferred")
    scenario.advanceAndFail()
    try await owner.refresh()
    await owner.waitForCollection()
    let failed = await owner.snapshot().accounts[0].groups.quotas
    #expect(failed.stale)
    #expect(failed.observedAt == first.accounts[0].groups.quotas.observedAt)
    #expect(failed.data?.windows[0].remainingPercent == 87.5)
    #expect(failed.error?.code == "provider_unavailable")
    await owner.shutdown()
    #expect(await owner.snapshot().status.owner == "shutting_down")
}

@Test func resetPassageDoesNotReplenish() throws {
    var window = try GoUsage.decode(fixture("go-valid")).windows[0]
    window.derive(at: window.resetAt!.addingTimeInterval(1), groupStale: false)
    #expect(window.stale)
    #expect(window.resetState == "passed")
    #expect(window.remainingPercent == 87.5)
    #expect(window.pacing == nil)
}

private final class InventoryScenario: @unchecked Sendable {
    private let lock = NSLock()
    private var value = InventoryRead(databaseIdentity: "database-a", credentials: [])
    private var failure = false
    func read() throws -> InventoryRead {
        try lock.withLock {
            if failure { throw Fault("inventory_schema_incompatible", "Synthetic schema failure.") }
            return value
        }
    }
    func set(_ credentials: [StoredCredential], database: String = "database-a") {
        lock.withLock { value = InventoryRead(databaseIdentity: database, credentials: credentials); failure = false }
    }
    func fail() { lock.withLock { failure = true } }
}

@Test func identityPreferencesSurviveRestartRemovalAndNamespaceSwitches() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = directory.appendingPathComponent("accounts.json")
    let scenario = InventoryScenario()
    let owner = TallyOwner(clock: { Date() }, storageURL: storage, inventory: { try scenario.read() }, collect: { _ in try GoUsage.decode(fixture("go-valid")) })
    scenario.fail()
    await #expect(throws: Fault.self) { try await owner.refresh() }
    scenario.set([])
    try await owner.refresh()
    let entries = (0..<8).map { StoredCredential(storedID: "row-\($0)", name: "Account \($0)", key: "secret-\($0)") }
    scenario.set(entries.reversed())
    try await owner.refresh()
    await owner.waitForCollection()
    let first = await owner.snapshot()
    #expect(first.accounts.map(\.identityColorIndex) == [0, 1, 2, 3, 4, 5, 0, 1])
    #expect(first.accounts.map(\.pinOrder) == Array(0..<8).map(Optional.some))
    let pins = [first.accounts[4].id, first.accounts[0].id]
    try await owner.setPins(pins)
    var renamed = entries
    renamed[0].name = "VERBATIM Renamed"
    scenario.set(renamed + [StoredCredential(storedID: "new", name: "Later", key: "new-secret")])
    try await owner.refresh(accountIDs: [])
    let changed = await owner.snapshot()
    #expect(changed.accounts.filter(\.pinned).map(\.id) == pins)
    #expect(changed.accounts.first(where: { $0.name == "VERBATIM Renamed" })?.id == first.accounts[0].id)
    #expect(changed.accounts.first(where: { $0.name == "Later" })?.pinned == false)
    #expect(changed.accounts.first(where: { $0.name == "Later" })?.identityColorIndex == 2)
    scenario.fail()
    await #expect(throws: Fault.self) { try await owner.refresh() }
    let failed = await owner.snapshot()
    #expect(failed.accounts.count == 9)
    #expect(failed.status.inventory.stale)
    #expect(failed.accounts.allSatisfy { $0.groups.quotas.stale })
    scenario.set(entries, database: "database-b")
    try await owner.refresh(accountIDs: [])
    let other = await owner.snapshot()
    #expect(other.status.inventory.data?.namespaceId != first.status.inventory.data?.namespaceId)
    #expect(Set(other.accounts.map(\.id)).isDisjoint(with: first.accounts.map(\.id)))
    #expect(other.accounts.allSatisfy { $0.groups.quotas.data == nil && $0.pinned })
    scenario.set(renamed + [StoredCredential(storedID: "new", name: "Later", key: "new-secret")])
    try await owner.refresh(accountIDs: [])
    let returned = await owner.snapshot()
    #expect(returned.accounts.filter(\.pinned).map(\.id) == pins)
    #expect(returned.accounts[0].groups.quotas.data != nil)
    #expect(returned.accounts[0].groups.quotas.stale)
    let restarted = TallyOwner(clock: { Date() }, storageURL: storage, inventory: { try scenario.read() }, collect: { _ in throw Fault("unexpected", "No collection expected.") })
    try await restarted.refresh(accountIDs: [])
    #expect(await restarted.snapshot().accounts.map(\.id) == returned.accounts.map(\.id))
    #expect(await restarted.snapshot().accounts.filter(\.pinned).map(\.id) == pins)
    scenario.set(Array(renamed.dropFirst()))
    try await restarted.refresh(accountIDs: [])
    #expect(await restarted.snapshot().accounts.contains { $0.id == first.accounts[0].id } == false)
    scenario.set(renamed)
    try await restarted.refresh(accountIDs: [])
    let restored = try await restarted.account(id: first.accounts[0].id).account
    #expect(!restored.pinned && restored.pinOrder == nil)
    #expect(restored.identityColorIndex == 0)
    #expect(restored.groups.quotas.data == nil)
    let saved = try String(contentsOf: storage, encoding: .utf8)
    #expect(!saved.contains("secret-0") && !saved.contains("row-0"))
    try await restarted.setPins([])
    #expect(await restarted.snapshot().accounts.allSatisfy { !$0.pinned && $0.pinOrder == nil })
}

@Test func oauthContinuityAndCommandEvidenceRemainConservative() async throws {
    let scenario = InventoryScenario()
    let owner = TallyOwner(clock: { Date() }, inventory: { try scenario.read() }, collect: { _ in throw Fault("unexpected", "Only Go collects in this slice.") })
    let claude = StoredCredential(storedID: "a", name: "same", key: "access", provider: "anthropic", refresh: "refresh")
    let workspace = StoredCredential(storedID: "b", name: "Same", key: "openai-access", provider: "openai", refresh: "openai-refresh", workspace: "workspace")
    scenario.set([workspace, claude])
    try await owner.refresh()
    let first = await owner.snapshot()
    #expect(first.accounts.map(\.provider) == ["anthropic", "openai"])
    let claudeID = first.accounts[0].id
    let openaiID = first.accounts[1].id
    let evidence = try await owner.identityEvidence(accountID: openaiID)
    var refreshed = claude; refreshed.key = "new-access"
    var openai = workspace; openai.key = "new-openai-access"; openai.refresh = "new-openai-refresh"
    scenario.set([refreshed, openai])
    try await owner.refresh(accountIDs: [])
    #expect(await owner.snapshot().accounts.map(\.id) == [claudeID, openaiID])
    #expect(try await owner.identityEvidence(accountID: openaiID).relation(to: evidence) == .same)
    refreshed.key = "replacement-access"; refreshed.refresh = "replacement-refresh"
    openai.workspace = "other-workspace"
    scenario.set([refreshed, openai])
    await #expect(throws: Fault.self) { try await owner.refresh(accountIDs: [openaiID]) }
    let replacement = await owner.snapshot()
    #expect(Set(replacement.accounts.map(\.id)).isDisjoint(with: first.accounts.map(\.id)))
    #expect(replacement.accounts.allSatisfy { !$0.pinned && $0.groups.quotas.data == nil })
    #expect(openai.evidence.relation(to: evidence) == .different)
    #expect(refreshed.evidence.relation(to: claude.evidence) == .uncertain)
    var unknownWorkspace = workspace; unknownWorkspace.workspace = nil
    #expect(unknownWorkspace.evidence.relation(to: evidence) == .uncertain)
    scenario.set([workspace], database: "other-db")
    try await owner.refresh(accountIDs: [])
    let crossNamespace = try #require(await owner.snapshot().accounts.first)
    #expect(crossNamespace.id != openaiID)
    #expect(try await owner.identityEvidence(accountID: crossNamespace.id).relation(to: evidence) == .same)
}

@Test func filesystemNamespaceAndSchemaFailuresAreIndependent() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("opencode.db").path
    func create(_ path: String) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TABLE credential (id TEXT, label TEXT, value TEXT, integration_id TEXT, time_created INTEGER); INSERT INTO credential VALUES ('same-row', 'Same', '{\"type\":\"key\",\"key\":\"same-key\"}', 'opencode-go', 1); CREATE TABLE message (incompatible TEXT);", nil, nil, nil) == SQLITE_OK)
    }
    try create(path)
    let owner = TallyOwner(databasePath: path, appBuild: "test", storageURL: directory.appendingPathComponent("state.json"))
    try await owner.refresh(accountIDs: [])
    let first = await owner.snapshot()
    #expect(first.accounts.count == 1)
    let alias = directory.appendingPathComponent("alias.db").path
    try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: path)
    try await owner.setDatabasePath(alias)
    #expect(await owner.snapshot().accounts.first?.id == first.accounts.first?.id)
    let old = path + ".old"
    try FileManager.default.moveItem(atPath: path, toPath: old)
    try create(path)
    try await owner.refresh(accountIDs: [])
    #expect(await owner.snapshot().status.inventory.data?.namespaceId != first.status.inventory.data?.namespaceId)
    #expect(await owner.snapshot().accounts.first?.id != first.accounts.first?.id)
    try await owner.setDatabasePath(old)
    #expect(await owner.snapshot().accounts.first?.id == first.accounts.first?.id)
    var db: OpaquePointer?
    #expect(sqlite3_open(old, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "ALTER TABLE credential RENAME COLUMN value TO incompatible", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    await #expect(throws: Fault.self) { try await owner.refresh(accountIDs: []) }
    #expect(await owner.snapshot().accounts.first?.id == first.accounts.first?.id)
    #expect(await owner.snapshot().status.inventory.error?.code == "inventory_schema_incompatible")
    await #expect(throws: Error.self) { try await owner.setDatabasePath(path + ".missing") }
    #expect(await owner.snapshot().accounts.isEmpty)
    #expect(await owner.snapshot().status.inventory.data == nil)
}

@Test func duplicateNamesAndProviderLocalPaletteHaveStableOrder() async throws {
    let entries = providerOrder.flatMap { provider in
        (0..<7).map { index in
            StoredCredential(storedID: "\(provider)-\(index)", name: index == 0 ? "Alpha" : "alpha", key: "\(provider)-secret-\(index)", provider: provider)
        }
    }
    let scenario = InventoryScenario()
    scenario.set(entries.reversed())
    let owner = TallyOwner(clock: { Date() }, inventory: { try scenario.read() }, collect: { _ in throw Fault("unexpected", "No collection expected.") })
    try await owner.refresh(accountIDs: [])
    let first = await owner.snapshot()
    #expect(first.accounts.map(\.provider) == providerOrder.flatMap { Array(repeating: $0, count: 7) })
    for provider in providerOrder {
        let accounts = first.accounts.filter { $0.provider == provider }
        #expect(accounts.map(\.identityColorIndex) == [0, 1, 2, 3, 4, 5, 0])
        #expect(accounts.map(\.name) == ["Alpha"] + Array(repeating: "alpha", count: 6))
    }
    scenario.set(entries)
    try await owner.refresh(accountIDs: [])
    #expect(await owner.snapshot().accounts.map(\.id) == first.accounts.map(\.id))
}

@Test func preferenceWriteFailureDoesNotStopCollectionOrClaimSavedPins() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("not-a-directory")
    try Data("blocking file".utf8).write(to: file)
    let owner = TallyOwner(clock: { Date() }, storageURL: file.appendingPathComponent("state.json"), inventory: {
        InventoryRead(databaseIdentity: "db", credentials: [StoredCredential(storedID: "row", name: "Go", key: "secret")])
    }, collect: { _ in try GoUsage.decode(fixture("go-valid")) })
    try await owner.refresh()
    await owner.waitForCollection()
    #expect(await owner.snapshot().accounts.first?.groups.quotas.data != nil)
    #expect(await owner.settingsError()?.code == "settings_storage_unavailable")
    await #expect(throws: Fault.self) { try await owner.setPins([]) }
    #expect(await owner.snapshot().accounts.first?.pinned == true)
    try FileManager.default.removeItem(at: file)
    try await owner.refresh(accountIDs: [])
    #expect(await owner.settingsError() == nil)
}

@Test func inventoryRescanPreservesInFlightReadingState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("opencode.db").path
    var db: OpaquePointer?
    #expect(sqlite3_open(path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "CREATE TABLE credential (id TEXT, label TEXT, value TEXT, integration_id TEXT, time_created INTEGER); INSERT INTO credential VALUES ('row', 'Go', '{\"type\":\"key\",\"key\":\"secret\"}', 'opencode-go', 1);", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let source = OpenCodeInventory(path: path)
    let (observations, continuation) = AsyncStream<GoObservation>.makeStream()
    let owner = TallyOwner(clock: { Date() }, inventory: {
        try source.read()
    }, collect: { _ in
        for await observation in observations { return observation }
        throw Fault("unexpected", "Missing synthetic observation.")
    })
    try await owner.refresh()
    let first = await owner.snapshot().accounts[0].groups.quotas
    #expect(first.refreshing)
    try await owner.setDatabasePath(path)
    #expect(try await owner.refresh().accounts[0].schedule.state == "joined")
    let joined = await owner.snapshot().accounts[0].groups.quotas
    #expect(joined.refreshing)
    #expect(joined.lastAttemptAt == first.lastAttemptAt)
    continuation.yield(try GoUsage.decode(fixture("go-valid")))
    continuation.finish()
    await owner.waitForCollection()
    #expect(await owner.snapshot().accounts[0].groups.quotas.data != nil)
    let alias = directory.appendingPathComponent("alias.db").path
    try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: path)
    try await owner.setDatabasePath(alias)
    #expect(await owner.snapshot().accounts[0].groups.quotas.stale == false)
}

private final class SchedulingScenario: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_900_000_000)
    private var counts: [String: Int] = [:]
    private var failures: [String: Fault] = [:]
    private var entries = [StoredCredential(storedID: "a", name: "A", key: "a"), StoredCredential(storedID: "b", name: "B", key: "b")]
    func now() -> Date { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    func count(_ key: String) -> Int { lock.withLock { counts[key, default: 0] } }
    func fail(_ key: String, _ fault: Fault?) { lock.withLock { failures[key] = fault } }
    func set(_ entries: [StoredCredential]) { lock.withLock { self.entries = entries } }
    func inventory() -> InventoryRead {
        lock.withLock { counts["inventory", default: 0] += 1; return InventoryRead(databaseIdentity: "db", credentials: entries) }
    }
    func call(_ key: String) throws {
        try lock.withLock { counts[key, default: 0] += 1; if let fault = failures[key] { throw fault } }
    }
    func owner(storage: URL? = nil) -> TallyOwner {
        TallyOwner(clock: { self.now() }, storageURL: storage, inventory: { self.inventory() }, scanActivity: { try self.call("activity") }, collect: { key in
            try self.call(key)
            return GoObservation(windows: [QuotaWindow(id: "rolling", label: "5-hour", cadence: "rolling", durationSeconds: 18_000,
                                                       durationSource: "verified_mapping", usedPercent: 20, resetAt: self.now().addingTimeInterval(9_000))])
        })
    }
}

@Test func controlledCadenceWakeMinimumAndRefreshValidation() async throws {
    let scenario = SchedulingScenario()
    let owner = scenario.owner()
    await owner.tick(); await owner.waitForCollection()
    let initial = await owner.snapshot()
    #expect(scenario.count("a") == 1 && scenario.count("b") == 1 && scenario.count("activity") == 1)
    #expect(initial.accounts[0].groups.quotas.nextAttemptAt == scenario.now().addingTimeInterval(120))
    scenario.advance(119)
    await owner.tick(); await owner.waitForCollection()
    #expect(scenario.count("a") == 1 && scenario.count("inventory") == 1)
    scenario.advance(1)
    await owner.tick(); await owner.waitForCollection()
    #expect(scenario.count("a") == 2 && scenario.count("inventory") == 2)
    let id = initial.accounts[0].id
    let duplicate = try await owner.refresh(accountIDs: [id, id])
    #expect(duplicate.accounts.count == 1 && duplicate.accounts[0].schedule.state == "deferred")
    await owner.waitForCollection()
    let scans = scenario.count("activity")
    await #expect(throws: Fault.self) { try await owner.refresh(accountIDs: [id, "unknown"]) }
    #expect(scenario.count("activity") == scans)
    #expect(try await owner.refresh(accountIDs: []).accounts.isEmpty)
    await owner.waitForCollection()
    #expect(scenario.count("activity") == scans + 1 && scenario.count("a") == 2)
    scenario.advance(14)
    #expect(try await owner.refresh(accountIDs: [id]).accounts[0].schedule.state == "deferred")
    await owner.waitForCollection()
    scenario.advance(1)
    #expect(try await owner.refresh(accountIDs: [id]).accounts[0].schedule.state == "started")
    await owner.waitForCollection()
    scenario.advance(15)
    await owner.wake(); await owner.waitForCollection()
    #expect(scenario.count("a") == 4 && scenario.count("b") == 3)
    #expect(await owner.snapshot().accounts[0].groups.quotas.observedAt == scenario.now())
}

@Test func backoffRetryAfterAndRestartRetainIndependentLastGoodReadings() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let scenario = SchedulingScenario()
    let storage = directory.appendingPathComponent("readings.json")
    let owner = scenario.owner(storage: storage)
    try await owner.refresh(); await owner.waitForCollection()
    let observed = scenario.now()
    scenario.fail("a", Fault("provider_unavailable", "Synthetic failure."))
    scenario.advance(15)
    for delay: TimeInterval in [120, 240, 480, 900, 900] {
        let response = try await owner.refresh()
        #expect(response.accounts[0].schedule.state == "started")
        await owner.waitForCollection()
        let snapshot = await owner.snapshot()
        #expect(snapshot.accounts[0].groups.quotas.observedAt == observed)
        #expect(snapshot.accounts[0].groups.quotas.data?.windows[0].usedPercent == 20)
        #expect(snapshot.accounts[0].groups.quotas.nextAttemptAt == scenario.now().addingTimeInterval(delay))
        #expect(snapshot.accounts[0].groups.quotas.error?.retryAt == scenario.now().addingTimeInterval(delay))
        #expect(!snapshot.accounts[1].groups.quotas.stale)
        let activityCalls = scenario.count("activity")
        #expect(try await owner.refresh().accounts[0].schedule.state == "deferred")
        await owner.waitForCollection()
        #expect(scenario.count("activity") == activityCalls + 1)
        scenario.advance(delay)
    }
    var longer = Fault("provider_unavailable", "Rate limited.")
    longer.retryAt = scenario.now().addingTimeInterval(3_600)
    scenario.fail("a", longer)
    try await owner.refresh(); await owner.waitForCollection()
    let restarted = scenario.owner(storage: storage)
    let restored = try await restarted.refresh()
    #expect(restored.accounts[0].schedule.state == "deferred")
    #expect(restored.accounts[0].schedule.nextAttemptAt == longer.retryAt)
    #expect(await restarted.snapshot().accounts[0].groups.quotas.stale)
    #expect(await restarted.snapshot().accounts[0].groups.quotas.observedAt == observed)
    let calls = scenario.count("a")
    scenario.advance(900)
    await restarted.wake(); await restarted.waitForCollection()
    #expect(scenario.count("a") == calls)
    scenario.fail("a", nil); scenario.advance(2_700)
    await restarted.tick(); await restarted.waitForCollection()
    #expect(scenario.count("a") == calls + 1)
    #expect(await restarted.snapshot().accounts[0].groups.quotas.nextAttemptAt == scenario.now().addingTimeInterval(120))
    #expect(!String(decoding: try Data(contentsOf: storage), as: UTF8.self).contains("\"key\""))
}

@Test func rejectedAndExpiredCredentialsRequireChangedUsableTokens() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let scenario = SchedulingScenario()
    var credential = StoredCredential(storedID: "a", name: "A", key: "old", refresh: "continuity", expiresAt: scenario.now().addingTimeInterval(60))
    scenario.set([credential])
    scenario.fail("old", Fault("credentials_rejected", "Rejected."))
    let owner = scenario.owner(storage: directory.appendingPathComponent("state.json"))
    try await owner.refresh(); await owner.waitForCollection()
    let id = try #require(await owner.snapshot().accounts.first?.id)
    scenario.advance(30)
    #expect(try await owner.refresh().accounts[0].schedule.state == "blocked")
    let restarted = scenario.owner(storage: directory.appendingPathComponent("state.json"))
    #expect(try await restarted.refresh().accounts[0].schedule.state == "blocked")
    #expect(scenario.count("old") == 1)
    credential.key = "new-expired"; credential.expiresAt = scenario.now()
    scenario.set([credential])
    #expect(try await restarted.refresh().accounts[0].schedule.reason?.code == "credentials_expired")
    #expect(scenario.count("new-expired") == 0)
    credential.expiresAt = scenario.now().addingTimeInterval(600)
    scenario.set([credential])
    #expect(try await restarted.refresh().accounts[0].schedule.state == "blocked")
    credential.key = "usable"
    scenario.set([credential])
    #expect(try await restarted.refresh().accounts[0].schedule.state == "started")
    await restarted.waitForCollection()
    #expect(await restarted.snapshot().accounts[0].id == id)
    #expect(scenario.count("usable") == 1)
}

@Test func independentGroupsKeepSuccessAbsenceAttemptAndFailureSeparate() async throws {
    let scenario = SchedulingScenario()
    let (values, continuation) = AsyncStream<[GroupObservation]>.makeStream()
    let owner = TallyOwner(clock: { scenario.now() }, inventory: { scenario.inventory() }, collections: { _ in
        [CollectionJob(id: "plan", groups: [.plan]) {
            for await value in values { return value }
            throw Fault("provider_unavailable", "Optional metadata failed.")
        }, CollectionJob(id: "usage", groups: [.quotas]) {
            [.quotas(Quotas(windows: []))]
        }]
    }, collect: { _ in throw Fault("unexpected", "Uses independent jobs.") })
    scenario.set([StoredCredential(storedID: "a", name: "A", key: "a")])
    try await owner.refresh()
    let started = scenario.now()
    #expect(try await owner.refresh().accounts[0].schedule.state == "joined")
    scenario.advance(30)
    continuation.yield([.plan(Plan(name: "Example"))])
    await owner.waitForCollection()
    var groups = await owner.snapshot().accounts[0].groups
    #expect(groups.plan.lastAttemptAt == started)
    #expect(groups.plan.observedAt == scenario.now())
    #expect(groups.quotas.data?.windows.isEmpty == true)
    scenario.advance(15)
    try await owner.refresh()
    continuation.yield([.plan(nil)])
    await owner.waitForCollection()
    groups = await owner.snapshot().accounts[0].groups
    #expect(groups.plan.data == nil && groups.plan.observedAt == scenario.now() && groups.plan.error == nil)
    let lastGood = groups.plan.observedAt
    continuation.finish()
    scenario.advance(15)
    try await owner.refresh(); await owner.waitForCollection()
    groups = await owner.snapshot().accounts[0].groups
    #expect(groups.plan.stale && groups.plan.observedAt == lastGood)
    #expect(!groups.quotas.stale && groups.quotas.observedAt == scenario.now())
    scenario.advance(15)
    #expect(try await owner.refresh().accounts[0].schedule.state == "started")
    await owner.waitForCollection()
    groups = await owner.snapshot().accounts[0].groups
    #expect(groups.plan.observedAt == lastGood && !groups.quotas.stale)
}

@Test func corruptedCacheStillCollectsAndAgeDoesNotChangeObservations() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = directory.appendingPathComponent("state.json")
    try Data("{damaged".utf8).write(to: storage)
    let scenario = SchedulingScenario()
    let owner = scenario.owner(storage: storage)
    try await owner.refresh(); await owner.waitForCollection()
    let first = await owner.snapshot()
    scenario.advance(299)
    #expect(await owner.snapshot().accounts[0].groups.quotas.stale == false)
    scenario.advance(1)
    let aged = await owner.snapshot()
    #expect(aged.accounts[0].groups.quotas.stale)
    #expect(aged.accounts[0].groups.quotas.observedAt == first.accounts[0].groups.quotas.observedAt)
    #expect(aged.accounts[0].groups.quotas.data?.windows[0].pacing == nil)
    #expect(scenario.count("a") == 1)
}

@Test func pacingBoundariesAndRetryAfterParsing() throws {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    func window(duration: Double?, elapsed: Double, used: Double? = 20) -> QuotaWindow {
        QuotaWindow(id: "quota", label: "Quota", cadence: "other", durationSeconds: duration, durationSource: duration == nil ? "unknown" : "provider",
                    usedPercent: used, resetAt: now.addingTimeInterval((duration ?? 1_000) - elapsed))
    }
    for (duration, minimum) in [(1_000.0, 60.0), (18_000.0, 180.0)] {
        var early = window(duration: duration, elapsed: minimum - 0.001)
        early.derive(at: now, groupStale: false)
        #expect(early.pacing == nil)
        var exact = window(duration: duration, elapsed: minimum)
        exact.derive(at: now, groupStale: false)
        #expect(exact.pacing?.projectedUsedPercent == 20 * duration / minimum)
        #expect(exact.pacing!.sparePercent < 0 && exact.pacing!.runOutAt! < exact.resetAt!)
    }
    var lasts = window(duration: 1_000, elapsed: 500, used: 10)
    lasts.derive(at: now, groupStale: false)
    #expect(lasts.pacing?.projectedUsedPercent == 20 && lasts.pacing?.sparePercent == 80)
    #expect(lasts.pacing?.runOutAt == nil && lasts.pacing?.runOutReason != nil)
    for var invalid in [window(duration: nil, elapsed: 500), window(duration: 0, elapsed: 0), window(duration: 1_000, elapsed: -1),
                        window(duration: 1_000, elapsed: 1_000), window(duration: 1_000, elapsed: 500, used: 0), window(duration: 1_000, elapsed: 500, used: nil)] {
        invalid.derive(at: now, groupStale: false)
        #expect(invalid.pacing == nil && invalid.pacingUnavailableReason != nil)
    }
    #expect(GoUsage.retryAfter("3600", at: now) == now.addingTimeInterval(3_600))
    #expect(GoUsage.retryAfter("Wed, 21 Oct 2037 07:28:00 GMT", at: now) != nil)
    #expect(GoUsage.retryAfter("invalid", at: now) == nil)
    #expect(GoUsage.retryAfter("-5", at: now) == nil)
    #expect(GoUsage.retryAfter("inf", at: now) == nil)
}

@Test func activityFailureKeepsItsLastSuccessAndNeverStalesProviderGroups() async throws {
    let scenario = SchedulingScenario()
    let owner = scenario.owner()
    try await owner.refresh(); await owner.waitForCollection()
    let success = await owner.activitySnapshot()
    #expect(success.observedAt == scenario.now() && !success.stale)
    scenario.advance(15)
    scenario.fail("activity", Fault("activity_unavailable", "Synthetic scan failure."))
    try await owner.refresh(); await owner.waitForCollection()
    let failed = await owner.activitySnapshot()
    #expect(failed.stale && failed.observedAt == success.observedAt && failed.lastAttemptAt == scenario.now())
    #expect(await owner.snapshot().accounts.allSatisfy { !$0.groups.quotas.stale })
    let calls = scenario.count("activity")
    scenario.fail("activity", nil)
    #expect(try await owner.refresh(accountIDs: []).activity.state == "started")
    await owner.waitForCollection()
    #expect(scenario.count("activity") == calls + 1)
    scenario.advance(300)
    #expect(await owner.activitySnapshot().stale)
    let unconnected = TallyOwner(clock: { scenario.now() }, inventory: { scenario.inventory() }, collect: { _ in GoObservation(windows: []) })
    try await unconnected.refresh(accountIDs: []); await unconnected.waitForCollection()
    #expect(await unconnected.activitySnapshot().observedAt == nil)
    #expect(await unconnected.activitySnapshot().error?.code == "not_implemented")
}
