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
    let owner = TallyOwner(clock: { Date() }, inventory: { [] }, collect: { _ in throw Fault("unexpected", "GET must not collect.") })
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("<html>Tally fixture</html>".utf8).write(to: directory.appendingPathComponent("index.html"))
    let app = try Application(responder: AuthorityResponder(next: TallyResponder(owner: owner, policy: HTTPPolicy(port: 7483, webOrigin: "https://Tally.Tail1234.ts.net"), assetDirectory: directory)))
    try await app.test(.router) { client in
        try await client.execute(uri: "/api/v1/refresh", method: .post, headers: [testAuthority: "tally.tail1234.ts.net", .contentType: "application/json", .origin: "https://tally.tail1234.ts.net"], body: .init(string: "{}")) { response in
            #expect(response.status == .ok)
        }
        for path in ["/", "/api/v1/status", "/api/v1/accounts"] {
            try await client.execute(uri: path, method: .get, headers: [testAuthority: "127.0.0.1:7483"]) { response in
                #expect(response.status == .ok)
            }
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
    let owner = TallyOwner(clock: { Date() }, inventory: { [] }, collect: { _ in throw Fault("unexpected", "No collection expected.") })
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
