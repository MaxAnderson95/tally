import Foundation
import Testing
import CSQLite
@testable import TallyCore

func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!)
}

@Test func decodesSharedWireFixture() throws {
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
}

@Test func inventoryRescanPreservesInFlightReadingState() async throws {
    let (observations, continuation) = AsyncStream<GoObservation>.makeStream()
    let owner = TallyOwner(clock: { Date() }, inventory: {
        InventoryRead(databaseIdentity: "db", credentials: [StoredCredential(storedID: "row", name: "Go", key: "secret")])
    }, collect: { _ in
        for await observation in observations { return observation }
        throw Fault("unexpected", "Missing synthetic observation.")
    })
    try await owner.refresh()
    let first = await owner.snapshot().accounts[0].groups.quotas
    #expect(first.refreshing)
    #expect(try await owner.refresh().accounts[0].schedule.state == "joined")
    let joined = await owner.snapshot().accounts[0].groups.quotas
    #expect(joined.refreshing)
    #expect(joined.lastAttemptAt == first.lastAttemptAt)
    continuation.yield(try GoUsage.decode(fixture("go-valid")))
    continuation.finish()
    await owner.waitForCollection()
    #expect(await owner.snapshot().accounts[0].groups.quotas.data != nil)
}
