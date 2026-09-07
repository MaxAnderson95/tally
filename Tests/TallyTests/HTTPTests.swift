import Foundation
import Testing
import Hummingbird
import HummingbirdTesting
import HTTPTypes
@testable import TallyCore
import TallyHTTP

private let testAuthority = HTTPField.Name("X-Test-Authority")!

// Hummingbird's router tester fixes authority to localhost. Supply the requested authority at its test seam.
private struct AuthorityResponder: HTTPResponder {
    typealias Context = BasicRequestContext
    let next: TallyResponder
    func respond(to request: Request, context: Context) async throws -> Response {
        var head = request.head
        head.authority = request.headers[testAuthority]
        return try await next.respond(to: Request(head: head, body: request.body), context: context)
    }
}

@Test func routesEnforcePolicyAndReadCachedState() async throws {
    let owner = TallyOwner(clock: { Date() }, inventory: {
        InventoryRead(databaseIdentity: "test-db", credentials: providerOrder.map {
            StoredCredential(storedID: $0, name: $0, key: "private-\($0)", provider: $0)
        })
    }, scanActivity: { cutoff in ActivityScan(databaseIdentity: "test-db", rows: [ActivityRow(created: cutoff.addingTimeInterval(-1), provider: "opencode-go", model: "grok-4.6", tokens: Tokens(input: 7, cacheWrite: 1, total: 8), cost: 0)]) }, collect: { _ in throw Fault("unexpected", "GET must not collect.") })
    try await owner.refresh(accountIDs: [])
    await owner.waitForCollection()
    let initial = await owner.snapshot()
    let pins = [initial.accounts[3].id, initial.accounts[0].id]
    try await owner.setPins(pins)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("<html>Tally fixture</html>".utf8).write(to: directory.appendingPathComponent("index.html"))
    let app = try Application(responder: AuthorityResponder(next: TallyResponder(owner: owner, policy: HTTPPolicy(port: 7483, webOrigin: "https://Tally.Tail1234.ts.net"), assetDirectory: directory)))
    try await app.test(.router) { client in
        try await client.execute(uri: "/api/v1/refresh", method: .post, headers: [testAuthority: "tally.tail1234.ts.net", .contentType: "application/json", .origin: "https://tally.tail1234.ts.net"], body: .init(string: "{}")) { response in
            #expect(response.status == .ok)
        }
        for path in ["/", "/api/v1/status", "/api/v1/accounts", "/api/v1/activity", "/api/v1/activity?range=yesterday", "/api/v1/activity?range=last30days"] {
            try await client.execute(uri: path, method: .get, headers: [testAuthority: "127.0.0.1:7483"]) { response in
                #expect(response.status == .ok)
            }
        }
        for query in ["range=bad", "range=", "range=today&range=yesterday"] {
            try await client.execute(uri: "/api/v1/activity?\(query)", method: .get, headers: [testAuthority: "127.0.0.1:7483"]) { response in
                #expect(response.status == .badRequest)
            }
        }
        try await client.execute(uri: "/api/v1/activity", method: .get, headers: [testAuthority: "127.0.0.1:7483"]) { response in
            let decoded = try Wire.decoder().decode(ActivityResponse.self, from: Data(response.body.readableBytesView))
            let native = await owner.activityResponse()
            #expect(try Wire.encoder().encode(decoded.activity) == Wire.encoder().encode(native.activity))
            #expect(decoded.activity.data?.trend.days.count == 30)
            #expect(decoded.activity.data?.totals.tokens?.total == 8)
            #expect(decoded.activity.data?.totals.estimate.status == "partial")
            #expect(decoded.activity.data?.totals.estimate.lower == "0.000014")
            #expect(decoded.activity.data?.totals.estimate.coverage.unpricedComponents.cacheWrite == 1)
            #expect(decoded.activity.data?.pricing.revision == "2026-09-07-r1")
        }
        try await client.execute(uri: "/api/v1/activity", method: .post, headers: [testAuthority: "127.0.0.1:7483", .contentType: "application/json"]) { response in
            #expect(response.status == .methodNotAllowed)
        }
        try await client.execute(uri: "/api/v1/accounts", method: .get, headers: [testAuthority: "127.0.0.1:7483"]) { response in
            let data = Data(response.body.readableBytesView)
            let decoded = try Wire.decoder().decode(AccountsResponse.self, from: data)
            #expect(decoded.accounts.filter(\.pinned).map(\.id) == pins)
            #expect(decoded.accounts.map(\.provider) == ["xai", "anthropic", "openai", "opencode-go"])
            #expect(!String(decoding: data, as: UTF8.self).contains("private-"))
        }
        for path in ["/api", "/api/nope", "/api/v1/nope", "/assets/missing.js", "/missing"] {
            try await client.execute(uri: path, method: .get, headers: [testAuthority: "127.0.0.1:7483"]) { response in
                #expect(response.status == .notFound)
                #expect(response.headers[.contentType] == "application/json")
            }
        }
        try await client.execute(uri: "/api/v1/accounts", method: .get, headers: [testAuthority: "evil.example"]) { response in
            #expect(response.status == .forbidden)
        }
        try await client.execute(uri: "/api/v1/refresh", method: .post, headers: [testAuthority: "127.0.0.1:7483", .contentType: "application/json", .origin: "https://evil.example"], body: .init(string: "{}")) { response in
            #expect(response.status == .forbidden)
        }
        try await client.execute(uri: "/api/v1/refresh", method: .post, headers: [testAuthority: "127.0.0.1:7483"], body: .init(string: "{}")) { response in
            #expect(response.status == .unsupportedMediaType)
        }
        for body in ["[]", "null", "{\"accountIds\":null}", "{\"accountIds\":[1]}"] {
            try await client.execute(uri: "/api/v1/refresh", method: .post, headers: [testAuthority: "127.0.0.1:7483", .contentType: "application/json"], body: .init(string: body)) { response in
                #expect(response.status == .badRequest)
            }
        }
        try await client.execute(uri: "/api/v1/refresh", method: .post, headers: [testAuthority: "127.0.0.1:7483", .contentType: "application/json"], body: .init(string: "{}")) { response in
            #expect(response.status == .ok)
        }
        try await client.execute(uri: "/api/v1/refresh", method: .get, headers: [testAuthority: "127.0.0.1:7483"]) { response in
            #expect(response.status == .methodNotAllowed)
        }
    }
}

@Test func listenerCollisionAndFreshLifetime() async throws {
    let owner = TallyOwner(clock: { Date() }, inventory: { InventoryRead(databaseIdentity: "test-db", credentials: []) }, collect: { _ in throw Fault("unexpected", "No collection expected.") })
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("Tally".utf8).write(to: directory.appendingPathComponent("index.html"))
    let responder = try TallyResponder(owner: owner, policy: HTTPPolicy(port: 7483), assetDirectory: directory)
    let (ports, ready) = AsyncStream<Int>.makeStream()
    let first = Application(responder: responder, configuration: .init(address: .hostname("127.0.0.1", port: 0)), onServerRunning: { channel in
        if let port = channel.localAddress?.port { ready.yield(port); ready.finish() }
    })
    let firstTask = Task { try await first.run() }
    let port = try #require(await ports.first(where: { _ in true }))
    let collision = try makeHTTPApplication(owner: owner, policy: HTTPPolicy(port: port), assetDirectory: directory)
    do {
        try await collision.run()
        Issue.record("A listener collision must fail rather than select a new port.")
    } catch {}
    #expect(try await owner.refresh().accounts.isEmpty)
    firstTask.cancel()
    _ = await firstTask.result
    let (restarted, signal) = AsyncStream<Bool>.makeStream()
    let fresh = Application(responder: responder, configuration: .init(address: .hostname("127.0.0.1", port: port)), onServerRunning: { _ in
        signal.yield(true); signal.finish()
    })
    let freshTask = Task { try await fresh.run() }
    #expect(await restarted.first(where: { _ in true }) == true)
    freshTask.cancel()
    _ = await freshTask.result
}

@Test(arguments: ["anthropic", "openai", "xai"]) func providerRESTMatchesNativeOwnerReadings(provider: String) async throws {
    let owner = TallyOwner(clock: { Date(timeIntervalSince1970: 1_915_031_000) }, inventory: {
        InventoryRead(databaseIdentity: "provider-db", credentials: [StoredCredential(storedID: "provider", name: "Fixture Account", key: "private-key", provider: provider)])
    }, collections: { _ in
        if provider == "xai" {
            return [CollectionJob(id: "billing", groups: [.quotas, .extraUsage, .balances, .resetSummary, .resetDetails]) { try GrokUsage.decode(fixture("grok-billing")) }]
        }
        if provider == "openai" {
            return [CollectionJob(id: "usage", groups: [.plan, .quotas, .extraUsage, .balances, .resetSummary]) {
                try OpenAIUsage.decodeUsage(fixture("openai-usage"), at: Date(timeIntervalSince1970: 1_915_031_000))
            }, CollectionJob(id: "credits", groups: [.resetDetails]) { [.resetDetails(try OpenAIUsage.decodeCredits(fixture("openai-credits")))] }]
        }
        return [CollectionJob(id: "usage", groups: [.quotas, .extraUsage, .balances, .resetSummary, .resetDetails]) {
        try AnthropicUsage.decode(fixture("anthropic-usage"))
    }] }, collect: { _ in throw Fault("unexpected", "No Go request expected.") })
    try await owner.refresh()
    await owner.waitForCollection()
    let native = await owner.snapshot()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("Tally".utf8).write(to: directory.appendingPathComponent("index.html"))
    let app = try Application(responder: AuthorityResponder(next: TallyResponder(owner: owner, policy: HTTPPolicy(port: 7483), assetDirectory: directory)))
    try await app.test(.router) { client in
        try await client.execute(uri: "/api/v1/accounts", method: .get, headers: [testAuthority: "127.0.0.1:7483"]) { response in
            let data = Data(response.body.readableBytesView)
            #expect(data == (try Wire.encoder().encode(native)))
            let account = try #require(Wire.decoder().decode(AccountsResponse.self, from: data).accounts.first)
            if provider == "anthropic" {
                #expect(account.groups.quotas.data?.windows.filter { !$0.displayInOverview }.map(\.id) == ["weekly_scoped:sonnet"])
                #expect(account.groups.extraUsage.data?.remaining?.amount == "8.75")
            } else if provider == "xai" {
                #expect(account.groups.quotas.data?.windows.first?.remainingPercent == 100)
                #expect(account.groups.extraUsage.data?.remaining?.amount == "2374.5")
                #expect(account.groups.extraUsage.data?.used?.currency == "credits")
            } else {
                #expect(account.groups.quotas.data?.windows.filter(\.displayInOverview).map(\.label) == ["Weekly"])
                #expect(account.groups.resetSummary.data?.source == "credit_details")
                #expect(account.groups.resetSummary.data?.applicableAvailableCount == nil)
                #expect(account.groups.resetDetails.data?.credits.map(\.expiry.kind) == ["at", "none", "unknown", "at"])
                #expect(account.groups.balances.data?.items.first?.referenceValue?.provenance == "reference_conversion")
            }
            #expect(!String(decoding: data, as: UTF8.self).contains("private-key"))
        }
    }
    await owner.shutdown()
}
