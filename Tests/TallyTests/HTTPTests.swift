import Foundation
import Testing
import Hummingbird
import HummingbirdTesting
import HTTPTypes
@testable import TallyCore
import TallyHTTP
@testable import TallyApp

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

@Test @MainActor func listenerCollisionAndFreshLifetime() async throws {
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
    let port = try #require(await ports.first(where: { @Sendable _ in true }))
    let suite = "tally-lifecycle-\(UUID().uuidString)"
    let settings = try #require(UserDefaults(suiteName: suite))
    defer { settings.removePersistentDomain(forName: suite) }
    settings.set(port, forKey: "port")
    let runtime = Runtime(owner: owner, settings: settings, assetDirectory: directory)
    runtime.startServer()
    for _ in 0..<100 where runtime.listenerError == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(runtime.listenerError != nil)
    #expect(settings.integer(forKey: "port") == port)
    runtime.webOrigin = "http://bad.example/path"
    await runtime.saveSettings()
    #expect(settings.string(forKey: "webOrigin") == nil)
    runtime.webOrigin = ""
    let collision = try makeHTTPApplication(owner: owner, policy: HTTPPolicy(port: port), assetDirectory: directory)
    do {
        try await collision.run()
        Issue.record("A listener collision must fail rather than select a new port.")
    } catch {}
    #expect(try await owner.refresh().accounts.isEmpty)
    firstTask.cancel()
    _ = await firstTask.result
    runtime.startServer()
    let url = URL(string: "http://127.0.0.1:\(port)/api/v1/status")!
    var reachable = false
    for _ in 0..<100 {
        if let (_, response) = try? await URLSession.shared.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200 { reachable = true; break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(reachable)
    #expect(runtime.listenerError == nil)
    await runtime.stop()
    #expect(await owner.snapshot().status.owner == "shutting_down")
    runtime.startServer()
    #expect((try? await URLSession.shared.data(from: url)) == nil)
    let (restarted, signal) = AsyncStream<Bool>.makeStream()
    let fresh = Application(responder: responder, configuration: .init(address: .hostname("127.0.0.1", port: port)), onServerRunning: { _ in
        signal.yield(true); signal.finish()
    })
    let freshTask = Task { try await fresh.run() }
    #expect(await restarted.first(where: { @Sendable _ in true }) == true)
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

@Test func redemptionRoutesExposeDurableStatusLocationAndStructuredErrors() async throws {
    let scenario = ResetScenario()
    let gate = ResetGate()
    let owner = scenario.owner(transport: { request in
        let response = try scenario.transport(request)
        if request.httpMethod == "POST" { await gate.wait(); throw URLError(.networkConnectionLost) }
        return response
    })
    let account = try await resetAccount(owner)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("Tally".utf8).write(to: directory.appendingPathComponent("index.html"))
    let app = try Application(responder: AuthorityResponder(next: TallyResponder(owner: owner, policy: HTTPPolicy(port: 7483), assetDirectory: directory)))
    let id = UUID().uuidString
    let submit = "/api/v1/accounts/\(account)/redemptions"
    let resultURL = "/api/v1/redemptions/\(id)"
    let body = "{\"operationId\":\"\(id)\"}"
    let headers: HTTPFields = [testAuthority: "127.0.0.1:7483", .contentType: "application/json"]
    try await app.test(.router) { client in
        for invalid in ["{}", "[]", "null", "{\"operationId\":null}", "{\"operationId\":\"bad\"}", "{\"operationId\":\"\(id)\",\"creditId\":null}", "{\"operationId\":\"\(id)\",\"creditId\":\"\"}"] {
            try await client.execute(uri: submit, method: .post, headers: headers, body: .init(string: invalid)) { response in #expect(response.status == .badRequest) }
        }
        try await client.execute(uri: submit, method: .post, headers: [testAuthority: "127.0.0.1:7483"], body: .init(string: body)) { response in #expect(response.status == .unsupportedMediaType) }
        try await client.execute(uri: submit, method: .post, headers: [testAuthority: "127.0.0.1:7483", .contentType: "application/json", .origin: "https://evil.example"], body: .init(string: body)) { response in #expect(response.status == .forbidden) }
        for _ in 0..<2 {
            try await client.execute(uri: submit, method: .post, headers: headers, body: .init(string: body)) { response in
                #expect(response.status == .accepted)
                #expect(response.headers[.location] == resultURL)
                let decoded = try Wire.decoder().decode(Redemption.self, from: Data(response.body.readableBytesView))
                #expect(decoded.state == .pending && decoded.resultUrl == resultURL && decoded.operationId == id)
            }
        }
        for conflicting in ["{\"operationId\":\"\(id)\",\"creditId\":\"credit-a\"}", "{\"operationId\":\"\(UUID().uuidString)\"}"] {
            try await client.execute(uri: submit, method: .post, headers: headers, body: .init(string: conflicting)) { response in
                #expect(response.status == .conflict)
                struct Envelope: Decodable { var error: Fault }
                let fault = try Wire.decoder().decode(Envelope.self, from: Data(response.body.readableBytesView)).error
                #expect(["operation_conflict", "account_blocked"].contains(fault.code))
                if fault.code == "account_blocked" { #expect(fault.blockingOperationId == id) }
            }
        }
        try await client.execute(uri: resultURL + "/acknowledge", method: .post, headers: headers, body: .init(string: "{}")) { response in #expect(response.status == .conflict) }
        for path in [submit, resultURL + "/acknowledge"] {
            try await client.execute(uri: path, method: .get, headers: headers) { response in #expect(response.status == .methodNotAllowed) }
        }
        try await client.execute(uri: resultURL, method: .post, headers: headers, body: .init(string: "{}")) { response in #expect(response.status == .methodNotAllowed) }
        try await client.execute(uri: "/api/v1/redemptions/bad", method: .get, headers: headers) { response in #expect(response.status == .badRequest) }
        try await client.execute(uri: "/api/v1/redemptions/\(UUID().uuidString)", method: .get, headers: headers) { response in #expect(response.status == .notFound) }
        await gate.open(); await owner.waitForRedemptions()
        try await client.execute(uri: resultURL, method: .get, headers: headers) { response in
            #expect(response.status == .ok)
            let decoded = try Wire.decoder().decode(Redemption.self, from: Data(response.body.readableBytesView))
            #expect(decoded.state == .unknown && decoded.acknowledgementRequired)
            #expect(try Wire.encoder().encode(decoded) == Wire.encoder().encode(await owner.redemption(operationID: id)))
        }
        try await client.execute(uri: submit, method: .post, headers: headers, body: .init(string: body)) { response in
            #expect(response.status == .ok && response.headers[.location] == resultURL)
        }
        for invalid in ["[]", "null", "{\"acknowledge\":true}"] {
            try await client.execute(uri: resultURL + "/acknowledge", method: .post, headers: headers, body: .init(string: invalid)) { response in #expect(response.status == .badRequest) }
        }
        for _ in 0..<2 {
            try await client.execute(uri: resultURL + "/acknowledge", method: .post, headers: headers, body: .init(string: "{}")) { response in
                #expect(response.status == .ok)
                let decoded = try Wire.decoder().decode(Redemption.self, from: Data(response.body.readableBytesView))
                #expect(decoded.state == .unknown && !decoded.acknowledgementRequired && decoded.acknowledgedAt != nil)
            }
        }
        scenario.fail(on: [5])
        try await client.execute(uri: submit, method: .post, headers: headers, body: .init(string: "{\"operationId\":\"\(UUID().uuidString)\"}")) { response in #expect(response.status == .serviceUnavailable) }
        await owner.shutdown()
        try await client.execute(uri: submit, method: .post, headers: headers, body: .init(string: "{\"operationId\":\"\(UUID().uuidString)\"}")) { response in #expect(response.status == .serviceUnavailable) }
    }
    #expect(scenario.calls().map(\.httpMethod) == ["GET", "POST"])
}
