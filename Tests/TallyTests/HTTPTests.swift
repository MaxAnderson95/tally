import Foundation
import Testing
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import CryptoKit
@testable import TallyCore
import TallyHTTP
@testable import TallyApp

private let testAuthority = HTTPField.Name("X-Test-Authority")!

// Hummingbird's router tester fixes authority to localhost. Supply the requested authority at its test seam.
// Route tests authenticate with the bearer token unless they bring their own credentials or clear `bearer`.
private struct AuthorityResponder: HTTPResponder {
    typealias Context = BasicRequestContext
    let next: TallyResponder
    var bearer: String? = testToken
    func respond(to request: Request, context: Context) async throws -> Response {
        var head = request.head
        head.authority = request.headers[testAuthority]
        if let bearer, head.headerFields[.authorization] == nil, head.headerFields[.cookie] == nil { head.headerFields[.authorization] = "Bearer " + bearer }
        return try await next.respond(to: Request(head: head, body: request.body), context: context)
    }
}

private let testToken = "test-token"
private func authState(_ directory: URL) -> URL { directory.appendingPathExtension("auth.json") }

@Test func warmupWebSettingsShareOwnerAndEnforceEligibility() async throws {
    let now = Date()
    let owner = TallyOwner(clock: { now }, warmupModels: { credential in
        [WarmupModel(id: credential.provider + "/cheap", name: "Cheap")]
    }, inventory: {
        InventoryRead(databaseIdentity: "web", credentials: [StoredCredential(storedID: "five-hour", name: "Five-hour", key: "synthetic"), StoredCredential(storedID: "weekly", name: "Weekly", key: "weekly", provider: "xai")])
    }, collections: { credential in
        [.go { GoObservation(windows: [QuotaWindow(id: "window", label: "Window", cadence: credential.provider == "xai" ? "weekly" : "rolling", durationSeconds: credential.provider == "xai" ? 604_800 : 18_000, durationSource: "provider", usedPercent: 0)]) }]
    }, collect: { _ in throw Fault("unexpected", "Unused collector") })
    await owner.tick(); await owner.waitForCollection()
    let accounts = await owner.snapshot().accounts
    let eligible = try #require(accounts.first(where: { $0.provider == "opencode-go" }))
    let weekly = try #require(accounts.first(where: { $0.provider == "xai" }))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: authState(directory)) }
    try Data("<html>Tally fixture</html>".utf8).write(to: directory.appendingPathComponent("index.html"))
    let app = try Application(responder: AuthorityResponder(next: TallyResponder(owner: owner, policy: HTTPPolicy(port: 7483, token: testToken), assetDirectory: directory, authStateURL: authState(directory))))
    try await app.test(.router) { client in
        let headers: HTTPFields = [testAuthority: "127.0.0.1:7483", .contentType: "application/json"]
        try await client.execute(uri: "/api/v1/warmups", method: .get, headers: headers) { response in
            #expect(response.status == .ok)
            let readings = try Wire.decoder().decode([String: WarmupReading].self, from: Data(response.body.readableBytesView))
            #expect(readings[eligible.id]?.unavailableReason == nil)
            #expect(readings[weekly.id]?.unavailableReason == "No applicable five-hour window")
            #expect(!String(buffer: response.body).contains("synthetic"))
        }
        let path = "/api/v1/accounts/\(eligible.id)/warmup"
        try await client.execute(uri: path + "/models", method: .get, headers: headers) { response in
            #expect(response.status == .ok)
            let models = try Wire.decoder().decode([WarmupModel].self, from: Data(response.body.readableBytesView))
            #expect(models.map(\.id) == ["opencode-go/cheap"])
        }
        try await client.execute(uri: path + "/models", method: .post, headers: headers) { #expect($0.status == .methodNotAllowed) }
        try await client.execute(uri: path, method: .put, headers: [testAuthority: "127.0.0.1:7483", .contentType: "application/json", .origin: "https://evil.example"], body: .init(string: "{\"enabled\":true,\"model\":\"opencode-go/cheap\"}")) { #expect($0.status == .forbidden) }
        for enabled in [true, false] {
            try await client.execute(uri: path, method: .put, headers: headers, body: .init(string: "{\"enabled\":\(enabled),\"model\":\"opencode-go/cheap\"}")) { response in
                #expect(response.status == .ok)
                let readings = try Wire.decoder().decode([String: WarmupReading].self, from: Data(response.body.readableBytesView))
                #expect(readings[eligible.id]?.enabled == enabled)
                #expect(await owner.warmupStatuses()[eligible.id]?.enabled == enabled)
            }
        }
        try await client.execute(uri: "/api/v1/accounts/\(weekly.id)/warmup", method: .put, headers: headers, body: .init(string: "{\"enabled\":true,\"model\":\"xai/cheap\"}")) { #expect($0.status == .badRequest) }
        try await client.execute(uri: path, method: .put, headers: headers, body: .init(string: "{\"enabled\":true}")) { #expect($0.status == .badRequest) }
        try await client.execute(uri: "/api/v1/accounts/missing/warmup", method: .put, headers: headers, body: .init(string: "{}")) { #expect($0.status == .notFound) }
    }
    await owner.shutdown()
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
    defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: authState(directory)) }
    try Data("<html>Tally fixture</html>".utf8).write(to: directory.appendingPathComponent("index.html"))
    let iconTypes = ["manifest.webmanifest": "application/manifest+json", "icon-192.png": "image/png", "favicon.ico": "image/x-icon", "favicon.svg": "image/svg+xml"]
    for name in iconTypes.keys { try Data(name.utf8).write(to: directory.appendingPathComponent(name)) }
    let app = try Application(responder: AuthorityResponder(next: TallyResponder(owner: owner, policy: HTTPPolicy(port: 7483, webOrigin: "https://Tally.Tail1234.ts.net", token: testToken), assetDirectory: directory, authStateURL: authState(directory))))
    try await app.test(.router) { client in
        for (name, type) in iconTypes {
            try await client.execute(uri: "/\(name)", method: .get, headers: [testAuthority: "127.0.0.1:7483"]) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == type)
            }
        }
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
        let colorPath = "/api/v1/accounts/\(initial.accounts[0].id)/color"
        for path in [colorPath, "/api/v1/pins", "/api/v1/unpinned-order"] {
            try await client.execute(uri: path, method: .put, headers: [testAuthority: "127.0.0.1:7483", .contentType: "application/json", .origin: "https://evil.example"], body: .init(string: "{}")) { response in
                #expect(response.status == .forbidden)
            }
            try await client.execute(uri: path, method: .put, headers: [testAuthority: "127.0.0.1:7483"], body: .init(string: "{}")) { response in
                #expect(response.status == .unsupportedMediaType)
            }
            try await client.execute(uri: path, method: .get, headers: [testAuthority: "127.0.0.1:7483"]) { response in
                #expect(response.status == .methodNotAllowed)
            }
            for body in ["{}", "null", "[]"] {
                try await client.execute(uri: path, method: .put, headers: [testAuthority: "127.0.0.1:7483", .contentType: "application/json"], body: .init(string: body)) { response in
                    #expect(response.status == .badRequest)
                }
            }
        }
        for body in ["{\"index\":6}", "{\"index\":-1}", "{\"index\":1.5}"] {
            try await client.execute(uri: colorPath, method: .put, headers: [testAuthority: "127.0.0.1:7483", .contentType: "application/json"], body: .init(string: body)) { response in
                #expect(response.status == .badRequest)
            }
        }
        try await client.execute(uri: colorPath, method: .put, headers: [testAuthority: "tally.tail1234.ts.net", .contentType: "application/json", .origin: "https://tally.tail1234.ts.net"], body: .init(string: "{\"index\":4}")) { response in
            #expect(response.status == .ok)
            let decoded = try Wire.decoder().decode(AccountsResponse.self, from: Data(response.body.readableBytesView))
            #expect(decoded.accounts.first { $0.id == initial.accounts[0].id }?.identityColorIndex == 4)
            #expect(try await owner.account(id: initial.accounts[0].id).account.identityColorIndex == 4)
        }
        let reordered = Array(pins.reversed())
        let pinBody = String(decoding: try JSONEncoder().encode(["accountIds": reordered]), as: UTF8.self)
        try await client.execute(uri: "/api/v1/pins", method: .put, headers: [testAuthority: "127.0.0.1:7483", .contentType: "application/json"], body: .init(string: pinBody)) { response in
            #expect(response.status == .ok)
            let decoded = try Wire.decoder().decode(AccountsResponse.self, from: Data(response.body.readableBytesView))
            #expect(decoded.accounts.filter(\.pinned).map(\.id) == reordered)
            #expect(await owner.snapshot().accounts.filter(\.pinned).map(\.id) == reordered)
        }
        for ids in [["missing"], [pins[0], pins[0]]] {
            let body = String(decoding: try JSONEncoder().encode(["accountIds": ids]), as: UTF8.self)
            try await client.execute(uri: "/api/v1/pins", method: .put, headers: [testAuthority: "127.0.0.1:7483", .contentType: "application/json"], body: .init(string: body)) { response in
                #expect(response.status == .badRequest)
                #expect(await owner.snapshot().accounts.filter(\.pinned).map(\.id) == reordered)
            }
        }
        let unpinned = Array(await owner.snapshot().accounts.filter { !$0.pinned }.map(\.id).reversed())
        let orderBody = String(decoding: try JSONEncoder().encode(["accountIds": unpinned]), as: UTF8.self)
        try await client.execute(uri: "/api/v1/unpinned-order", method: .put, headers: [testAuthority: "127.0.0.1:7483", .contentType: "application/json"], body: .init(string: orderBody)) { response in
            #expect(response.status == .ok)
            let decoded = try Wire.decoder().decode(AccountsResponse.self, from: Data(response.body.readableBytesView))
            #expect(decoded.accounts.filter { !$0.pinned }.map(\.id) == unpinned)
            #expect(decoded.accounts.filter(\.pinned).map(\.id) == reordered)
        }
    }
}

@Test func accountSelectionRouteSharesStateAndRejectsInvalidCommands() async throws {
    let scenario = SelectionScenario()
    let owner = scenario.owner()
    _ = try await owner.refresh(accountIDs: [])
    let target = try #require(await owner.snapshot().accounts.first(where: { $0.name == "b" }))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: authState(directory)) }
    try Data("<html>Fixture</html>".utf8).write(to: directory.appendingPathComponent("index.html"))
    let app = try Application(responder: AuthorityResponder(next: TallyResponder(owner: owner, policy: HTTPPolicy(port: 7483, token: testToken), assetDirectory: directory, authStateURL: authState(directory))))
    try await app.test(.router) { client in
        let path = "/api/v1/accounts/\(target.id)/activate"
        let headers: HTTPFields = [testAuthority: "127.0.0.1:7483", .contentType: "application/json"]
        try await client.execute(uri: path, method: .get, headers: headers) { #expect($0.status == .methodNotAllowed) }
        try await client.execute(uri: path, method: .post, headers: headers, body: .init(string: "{\"active\":false}")) { #expect($0.status == .badRequest) }
        try await client.execute(uri: path, method: .post, headers: [testAuthority: "127.0.0.1:7483", .contentType: "application/json", .origin: "https://evil.example"], body: .init(string: "{}")) { #expect($0.status == .forbidden) }
        #expect(scenario.count() == 0)
        try await client.execute(uri: path, method: .post, headers: headers, body: .init(string: "{}")) { response in
            #expect(response.status == .ok)
            let result = try Wire.decoder().decode(AccountsResponse.self, from: Data(response.body.readableBytesView))
            #expect(result.accounts.first(where: { $0.id == target.id })?.active == true)
            #expect(!String(buffer: response.body).contains("synthetic"))
        }
        #expect(scenario.count() == 1)
    }
    await owner.shutdown()
}

@Test @MainActor func listenerCollisionAndFreshLifetime() async throws {
    let owner = TallyOwner(clock: { Date() }, inventory: { InventoryRead(databaseIdentity: "test-db", credentials: []) }, collect: { _ in throw Fault("unexpected", "No collection expected.") })
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: authState(directory)) }
    try Data("Tally".utf8).write(to: directory.appendingPathComponent("index.html"))
    let responder = try TallyResponder(owner: owner, policy: HTTPPolicy(port: 7483, token: testToken), assetDirectory: directory, authStateURL: authState(directory))
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
    var secrets: [String: String] = [:]
    let runtime = Runtime(owner: owner, settings: settings, assetDirectory: directory,
                          secrets: ServeSecrets(read: { secrets[$0] ?? "" }, write: { secrets[$0] = $1 }), authStateURL: authState(directory))
    runtime.startServer()
    #expect(runtime.listenerError == "Set a web password or API token in Tally Settings to serve the web UI and API.")
    runtime.apiToken = testToken
    runtime.startServer()
    for _ in 0..<100 where runtime.listenerError == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(runtime.listenerError != nil)
    #expect(settings.integer(forKey: "port") == port)
    runtime.webOrigin = "http://bad.example/path"
    await runtime.saveSettings()
    #expect(settings.string(forKey: "webOrigin") == nil)
    #expect(secrets.isEmpty)
    runtime.webOrigin = ""
    let collision = try makeHTTPApplication(owner: owner, policy: HTTPPolicy(port: port, token: testToken), assetDirectory: directory, authStateURL: authState(directory))
    do {
        try await collision.run()
        Issue.record("A listener collision must fail rather than select a new port.")
    } catch {}
    #expect(try await owner.refresh().accounts.isEmpty)
    firstTask.cancel()
    _ = await firstTask.result
    runtime.startServer()
    let url = URL(string: "http://127.0.0.1:\(port)/api/v1/status")!
    var authorized = URLRequest(url: url)
    authorized.setValue("Bearer " + testToken, forHTTPHeaderField: "Authorization")
    var reachable = false
    for _ in 0..<100 {
        if let (_, response) = try? await URLSession.shared.data(for: authorized), (response as? HTTPURLResponse)?.statusCode == 200 { reachable = true; break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(reachable)
    let (_, anonymous) = try await URLSession.shared.data(from: url)
    #expect((anonymous as? HTTPURLResponse)?.statusCode == 401)
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
    defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: authState(directory)) }
    try Data("Tally".utf8).write(to: directory.appendingPathComponent("index.html"))
    let app = try Application(responder: AuthorityResponder(next: TallyResponder(owner: owner, policy: HTTPPolicy(port: 7483, token: testToken), assetDirectory: directory, authStateURL: authState(directory))))
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
    defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: authState(directory)) }
    try Data("Tally".utf8).write(to: directory.appendingPathComponent("index.html"))
    let app = try Application(responder: AuthorityResponder(next: TallyResponder(owner: owner, policy: HTTPPolicy(port: 7483, token: testToken), assetDirectory: directory, authStateURL: authState(directory))))
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

/// A software passkey authenticator: "none" attestation and ES256 assertions, encoded the way browsers hand them to SimpleWebAuthn.
private struct SoftAuthenticator {
    let key = P256.Signing.PrivateKey()
    let credentialID = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    var counter: UInt32 = 0

    static func b64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func bytes(_ b64url: String) -> Data {
        var text = b64url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)!
    }
    private static func cborBytes(_ data: Data, major: UInt8 = 0x40) -> Data {
        precondition(data.count < 65_536)
        if data.count < 24 { return Data([major | UInt8(data.count)]) + data }
        if data.count < 256 { return Data([major | 24, UInt8(data.count)]) + data }
        return Data([major | 25, UInt8(data.count >> 8), UInt8(data.count & 0xff)]) + data
    }
    private static func cborText(_ text: String) -> Data { cborBytes(Data(text.utf8), major: 0x60) }

    private func authenticatorData(rpID: String, attested: Bool) -> Data {
        var data = Data(SHA256.hash(data: Data(rpID.utf8)))
        data.append(attested ? 0x45 : 0x05)
        data.append(contentsOf: withUnsafeBytes(of: counter.bigEndian, Array.init))
        guard attested else { return data }
        let point = key.publicKey.x963Representation
        data.append(Data(count: 16))
        data.append(contentsOf: [UInt8(credentialID.count >> 8), UInt8(credentialID.count & 0xff)])
        data.append(credentialID)
        data.append(Data([0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21]) + Self.cborBytes(point[1..<33]) + Data([0x22]) + Self.cborBytes(point[33..<65]))
        return data
    }

    private func clientData(_ type: String, _ options: [String: Any], origin: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["type": type, "challenge": options["challenge"] as! String, "origin": origin])
    }

    func registration(_ options: [String: Any], origin: String) -> [String: Any] {
        let rpID = (options["rp"] as! [String: Any])["id"] as! String
        let attestation = Data([0xA3]) + Self.cborText("fmt") + Self.cborText("none") + Self.cborText("attStmt") + Data([0xA0])
            + Self.cborText("authData") + Self.cborBytes(authenticatorData(rpID: rpID, attested: true))
        let id = Self.b64url(credentialID)
        return ["id": id, "rawId": id, "type": "public-key",
                "response": ["clientDataJSON": Self.b64url(clientData("webauthn.create", options, origin: origin)), "attestationObject": Self.b64url(attestation)]]
    }

    /// Signs for `origin` and its host as RP ID, as an authenticator bound to that origin would.
    mutating func assertion(_ options: [String: Any], origin: String) throws -> [String: Any] {
        counter += 1
        let authData = authenticatorData(rpID: URL(string: origin)!.host!, attested: false)
        let client = clientData("webauthn.get", options, origin: origin)
        let signature = try key.signature(for: authData + Data(SHA256.hash(data: client))).derRepresentation
        let id = Self.b64url(credentialID)
        return ["id": id, "rawId": id, "type": "public-key",
                "response": ["clientDataJSON": Self.b64url(client), "authenticatorData": Self.b64url(authData), "signature": Self.b64url(signature)]]
    }
}

private func object(_ response: TestResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
}
private func jsonBody(_ value: [String: Any]) throws -> ByteBuffer { ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: value)) }
private func sessionCookie(_ response: TestResponse) -> String? {
    response.headers[values: .setCookie].first { $0.hasPrefix("tally_session=") }.map { String($0.split(separator: ";")[0]) }
}
private func with(_ fields: HTTPFields, _ extra: HTTPFields) -> HTTPFields { var fields = fields; fields.append(contentsOf: extra); return fields }

@Test func authenticationGuardsEveryRouteAndSupportsPasswordPasskeysAndBearer() async throws {
    let owner = TallyOwner(clock: { Date() }, inventory: { InventoryRead(databaseIdentity: "auth-db", credentials: []) }, collect: { _ in throw Fault("unexpected", "No collection expected.") })
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: authState(directory)) }
    try Data("<html>Tally fixture</html>".utf8).write(to: directory.appendingPathComponent("index.html"))
    let tunnel = "tally.abc123.opentunnel.xyz"
    let policy = HTTPPolicy(port: 7483, webOrigin: "https://\(tunnel)", password: "hunter2", token: testToken)
    let responder = try TallyResponder(owner: owner, policy: policy, assetDirectory: directory, authStateURL: authState(directory))
    let attributes = try FileManager.default.attributesOfItem(atPath: authState(directory).path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
    #expect(throws: Fault.self) { try TallyResponder(owner: owner, policy: HTTPPolicy(port: 7483), assetDirectory: directory, authStateURL: authState(directory)) }

    let local: HTTPFields = [testAuthority: "localhost:7483", .contentType: "application/json"]
    let localPage = with(local, [.origin: "http://localhost:7483"])
    let tunnelPage: HTTPFields = [testAuthority: tunnel, .contentType: "application/json", .origin: "https://\(tunnel)"]
    let password = ByteBuffer(string: "{\"password\":\"hunter2\"}")
    let empty = ByteBuffer(string: "{}")

    try await Application(responder: AuthorityResponder(next: responder, bearer: nil)).test(.router) { client in
        #expect(try await client.execute(uri: "/", method: .get, headers: local).status == .ok)
        for path in ["/api/v1/status", "/api/v1/accounts", "/api/v1/activity", "/api/v1/warmups", "/api/v1/auth/passkeys", "/api/v1/auth/me"] {
            #expect(try await client.execute(uri: path, method: .get, headers: local).status == .unauthorized)
        }
        #expect(try await client.execute(uri: "/api/v1/refresh", method: .post, headers: local, body: empty).status == .unauthorized)
        let state = try object(try await client.execute(uri: "/api/v1/auth/state", method: .get, headers: local))
        #expect(state["passwordEnabled"] as? Bool == true && state["hasPasskeys"] as? Bool == false)

        #expect(try await client.execute(uri: "/api/v1/status", method: .get, headers: with(local, [.authorization: "Bearer wrong"])).status == .unauthorized)
        #expect(try await client.execute(uri: "/api/v1/status", method: .get, headers: with(local, [.authorization: "Bearer " + testToken])).status == .ok)
        #expect(try await client.execute(uri: "/api/v1/refresh", method: .post, headers: with(local, [.authorization: "Bearer " + testToken]), body: empty).status == .ok)

        let wrong = try await client.execute(uri: "/api/v1/auth/login", method: .post, headers: local, body: ByteBuffer(string: "{\"password\":\"wrong\"}"))
        #expect(wrong.status == .unauthorized && sessionCookie(wrong) == nil)
        #expect(try await client.execute(uri: "/api/v1/auth/login", method: .post, headers: with(local, [.origin: "http://127.0.0.1:7483"]), body: password).status == .forbidden)
        let login = try await client.execute(uri: "/api/v1/auth/login", method: .post, headers: localPage, body: password)
        #expect(login.status == .ok)
        let header = try #require(login.headers[values: .setCookie].first)
        #expect(header.contains("HttpOnly") && header.contains("SameSite=Strict") && header.contains("Max-Age=2592000") && !header.contains("Secure"))
        let cookie = try #require(sessionCookie(login))
        let secure = try await client.execute(uri: "/api/v1/auth/login", method: .post, headers: tunnelPage, body: password)
        #expect(secure.headers[values: .setCookie].first?.contains("Secure") == true)

        #expect(try await client.execute(uri: "/api/v1/status", method: .get, headers: with(local, [.cookie: cookie])).status == .ok)
        #expect(try object(try await client.execute(uri: "/api/v1/auth/me", method: .get, headers: with(local, [.cookie: cookie])))["method"] as? String == "cookie")
        #expect(try await client.execute(uri: "/api/v1/status", method: .get, headers: with(local, [.cookie: cookie + "x"])).status == .unauthorized)
        #expect(try await client.execute(uri: "/api/v1/status", method: .get, headers: with(local, [.cookie: cookie, .authorization: "Bearer wrong"])).status == .unauthorized)
        let crossSite = try await client.execute(uri: "/api/v1/refresh", method: .post, headers: with(local, [.cookie: cookie]), body: empty)
        #expect(crossSite.status == .forbidden && String(buffer: crossSite.body).contains("cross_origin"))
        #expect(try await client.execute(uri: "/api/v1/refresh", method: .post, headers: with(local, [.cookie: cookie, HTTPField.Name("Sec-Fetch-Site")!: "same-origin"]), body: empty).status == .ok)
        #expect(try await client.execute(uri: "/api/v1/refresh", method: .post, headers: with(localPage, [.cookie: cookie]), body: empty).status == .ok)

        // Passkeys are origin-bound: an assertion made for localhost cannot sign in through the tunnel, and vice versa.
        var authenticators: [String: SoftAuthenticator] = [:]
        for (headers, origin) in [(localPage, "http://localhost:7483"), (tunnelPage, "https://\(tunnel)")] {
            #expect(try await client.execute(uri: "/api/v1/auth/passkeys/register/begin", method: .post, headers: headers, body: empty).status == .unauthorized)
            let begin = try object(try await client.execute(uri: "/api/v1/auth/passkeys/register/begin", method: .post, headers: with(headers, [.cookie: cookie]), body: empty))
            let options = try #require(begin["options"] as? [String: Any])
            #expect((options["rp"] as? [String: Any])?["id"] as? String == URL(string: origin)?.host)
            #expect((options["excludeCredentials"] as? [Any])?.count == authenticators.count)
            let authenticator = SoftAuthenticator()
            let finish = try jsonBody(["ceremonyId": try #require(begin["ceremonyId"] as? String), "name": "Phone", "credential": authenticator.registration(options, origin: origin)])
            #expect(try await client.execute(uri: "/api/v1/auth/passkeys/register/finish", method: .post, headers: with(headers, [.cookie: cookie]), body: finish).status == .ok)
            let replay = try await client.execute(uri: "/api/v1/auth/passkeys/register/finish", method: .post, headers: with(headers, [.cookie: cookie]), body: finish)
            #expect(replay.status == .badRequest && String(buffer: replay.body).contains("ceremony_expired"))
            authenticators[origin] = authenticator
        }
        for (headers, origin, other) in [(localPage, "http://localhost:7483", "https://\(tunnel)"), (tunnelPage, "https://\(tunnel)", "http://localhost:7483")] {
            for (signer, expected) in [(other, HTTPResponse.Status.unauthorized), (origin, .ok)] {
                let begin = try object(try await client.execute(uri: "/api/v1/auth/passkeys/login/begin", method: .post, headers: headers, body: empty))
                var authenticator = try #require(authenticators[signer])
                let assertion = try authenticator.assertion(try #require(begin["options"] as? [String: Any]), origin: signer)
                authenticators[signer] = authenticator
                let finish = try await client.execute(uri: "/api/v1/auth/passkeys/login/finish", method: .post, headers: headers,
                                                      body: try jsonBody(["ceremonyId": try #require(begin["ceremonyId"] as? String), "credential": assertion]))
                #expect(finish.status == expected)
                #expect((sessionCookie(finish) != nil) == (expected == .ok))
            }
        }

        let passkeys = try #require(try object(try await client.execute(uri: "/api/v1/auth/passkeys", method: .get, headers: with(local, [.cookie: cookie])))["passkeys"] as? [[String: Any]])
        #expect(passkeys.count == 2)
        #expect(passkeys.allSatisfy { $0["name"] as? String == "Phone" && $0["lastUsedAt"] is String })
        let id = try #require(passkeys.first?["id"] as? String)
        #expect(try await client.execute(uri: "/api/v1/auth/passkeys/\(id)", method: .delete, headers: with(local, [.cookie: cookie]), body: empty).status == .forbidden)
        #expect(try await client.execute(uri: "/api/v1/auth/passkeys/\(id)", method: .delete, headers: with(localPage, [.cookie: cookie]), body: empty).status == .ok)
        #expect(try await client.execute(uri: "/api/v1/auth/passkeys/\(id)", method: .delete, headers: with(localPage, [.cookie: cookie]), body: empty).status == .notFound)

        #expect(try await client.execute(uri: "/api/v1/auth/logout", method: .post, headers: with(local, [.origin: "https://evil.example"]), body: empty).status == .forbidden)
        let logout = try await client.execute(uri: "/api/v1/auth/logout", method: .post, headers: localPage, body: empty)
        #expect(logout.status == .ok && logout.headers[values: .setCookie].first?.contains("Max-Age=0") == true)
    }

    // Sessions are signed with the persisted key, so a restarted server, here token-only, still accepts them.
    let cookie = try await Application(responder: AuthorityResponder(next: responder, bearer: nil)).test(.router) { client in
        try #require(sessionCookie(try await client.execute(uri: "/api/v1/auth/login", method: .post, headers: localPage, body: password)))
    }
    let tokenOnly = try TallyResponder(owner: owner, policy: HTTPPolicy(port: 7483, token: testToken), assetDirectory: directory, authStateURL: authState(directory))
    try await Application(responder: AuthorityResponder(next: tokenOnly, bearer: nil)).test(.router) { client in
        #expect(try await client.execute(uri: "/api/v1/status", method: .get, headers: with(local, [.cookie: cookie])).status == .ok)
        let state = try object(try await client.execute(uri: "/api/v1/auth/state", method: .get, headers: local))
        #expect(state["passwordEnabled"] as? Bool == false && state["hasPasskeys"] as? Bool == true)
        let login = try await client.execute(uri: "/api/v1/auth/login", method: .post, headers: localPage, body: password)
        #expect(login.status == .forbidden && String(buffer: login.body).contains("password_disabled"))
    }
    await owner.shutdown()
}
