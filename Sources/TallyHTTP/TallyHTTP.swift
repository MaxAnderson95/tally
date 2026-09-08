import Foundation
import Hummingbird
import TallyCore

public struct HTTPPolicy: Sendable {
    public var port: Int
    public var allowedHosts: Set<String>
    public var allowedOrigins: Set<String>
    public init(port: Int, webOrigin: String? = nil) {
        self.port = port
        allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        allowedOrigins = ["http://127.0.0.1:\(port)", "http://localhost:\(port)"]
        if let webOrigin, let url = URL(string: webOrigin), let host = url.host {
            allowedHosts.insert(host.lowercased() + (url.port.map { ":\($0)" } ?? ""))
            allowedOrigins.insert(webOrigin.lowercased())
        }
    }
}

public struct TallyResponder: HTTPResponder {
    public typealias Context = BasicRequestContext
    let owner: TallyOwner
    let policy: HTTPPolicy
    let assets: [String: Data]

    public init(owner: TallyOwner, policy: HTTPPolicy, assetDirectory: URL) throws {
        self.owner = owner; self.policy = policy
        let assetDirectory = assetDirectory.resolvingSymlinksInPath().standardizedFileURL
        var assets: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(at: assetDirectory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw Fault("assets_unavailable", "Bundled web assets are missing. Rebuild the Tally app.")
        }
        for case let file as URL in enumerator {
            let file = file.resolvingSymlinksInPath().standardizedFileURL
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let relative = "/" + file.pathComponents.dropFirst(assetDirectory.pathComponents.count).joined(separator: "/")
            assets[relative] = try Data(contentsOf: file)
        }
        guard assets["/index.html"] != nil else { throw Fault("assets_unavailable", "Bundled web index is missing. Rebuild the Tally app.") }
        self.assets = assets
    }

    public func respond(to request: Request, context: Context) async throws -> Response {
        guard let host = request.head.authority?.lowercased(), policy.allowedHosts.contains(host) else {
            return failure(.forbidden, Fault("host_rejected", "Host is not allowed."))
        }
        let path = request.uri.path
        let isAPI = path == "/api" || path.hasPrefix("/api/")
        if request.method != .get && request.method != .head {
            if let origin = request.headers[.origin], !policy.allowedOrigins.contains(origin) {
                return failure(.forbidden, Fault("origin_rejected", "Origin is not allowed."))
            }
            guard request.headers[.contentType]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
                return failure(.unsupportedMediaType, Fault("json_required", "Mutations require application/json."))
            }
        }
        if !isAPI {
            guard request.method == .get || request.method == .head else { return failure(.methodNotAllowed, Fault("method_not_allowed", "Method not allowed.")) }
            guard let data = assets[path == "/" ? "/index.html" : path] else { return failure(.notFound, Fault("not_found", "Asset not found.")) }
            let type: String
            switch URL(fileURLWithPath: path).pathExtension {
            case "js": type = "text/javascript; charset=utf-8"
            case "css": type = "text/css; charset=utf-8"
            case "svg": type = "image/svg+xml"
            default: type = "text/html; charset=utf-8"
            }
            return Response(status: .ok, headers: [.contentType: type, .cacheControl: "no-store"], body: request.method == .head ? .init() : .init(byteBuffer: .init(bytes: data)))
        }
        do {
            if path == "/api/v1/refresh" {
                guard request.method == .post else { return failure(.methodNotAllowed, Fault("method_not_allowed", "Use POST for refresh.")) }
                let buffer = try await request.body.collect(upTo: 16_384)
                struct Input: Decodable {
                    var accountIds: [String]?
                    enum CodingKeys: String, CodingKey { case accountIds }
                    init(from decoder: any Decoder) throws {
                        let fields = try decoder.container(keyedBy: CodingKeys.self)
                        accountIds = fields.contains(.accountIds) ? try fields.decode([String].self, forKey: .accountIds) : nil
                    }
                }
                let data = Data(buffer.readableBytesView)
                guard let input = try? JSONDecoder().decode(Input.self, from: data) else {
                    return failure(.badRequest, Fault("invalid_request", "Expected an object with optional accountIds array."))
                }
                return try json(await owner.refresh(accountIDs: input.accountIds))
            }
            let detailPrefix = "/api/v1/accounts/"
            let knownRead = path == "/api/v1/status" || path == "/api/v1/accounts" ||
                (path.hasPrefix(detailPrefix) && !path.dropFirst(detailPrefix.count).contains("/") && path.count > detailPrefix.count)
            guard knownRead else { return failure(.notFound, Fault("not_found", "API route not found.")) }
            guard request.method == .get else { return failure(.methodNotAllowed, Fault("method_not_allowed", "Use GET for cached readings.")) }
            if path == "/api/v1/status" { return try json(await owner.snapshot().status) }
            if path == "/api/v1/accounts" { return try json(await owner.snapshot()) }
            return try json(await owner.account(id: String(path.dropFirst(detailPrefix.count))))
        } catch let fault as Fault {
            return failure(fault.code == "account_not_found" ? .notFound : .serviceUnavailable, fault)
        } catch {
            return failure(.badRequest, Fault("invalid_request", "Request could not be processed."))
        }
    }

    private func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
        Response(status: status, headers: [.contentType: "application/json", .cacheControl: "no-store"],
                 body: .init(byteBuffer: .init(bytes: try Wire.encoder().encode(value))))
    }
    private func failure(_ status: HTTPResponse.Status, _ fault: Fault) -> Response {
        struct Envelope: Encodable { var error: Fault }
        return try! json(Envelope(error: fault), status: status)
    }
}

public func makeHTTPApplication(owner: TallyOwner, policy: HTTPPolicy, assetDirectory: URL) throws -> Application<TallyResponder> {
    try Application(responder: TallyResponder(owner: owner, policy: policy, assetDirectory: assetDirectory),
                    configuration: .init(address: .hostname("127.0.0.1", port: policy.port), serverName: "Tally"))
}
