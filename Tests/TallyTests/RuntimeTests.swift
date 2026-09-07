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
    """
    #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let before = try Data(contentsOf: URL(fileURLWithPath: path))
    let credentials = try OpenCodeInventory(path: path).read()
    #expect(credentials.map(\.name) == ["Go Personal", "WORK"])
    #expect(credentials.map(\.key) == ["key-a", "key-b"])
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
        [GoCredential(storedID: "cred-secret", name: "Fixture Go", key: "test-secret")]
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
