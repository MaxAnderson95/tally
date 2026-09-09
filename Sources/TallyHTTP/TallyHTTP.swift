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
            case "png": type = "image/png"
            case "ico": type = "image/x-icon"
            case "webmanifest": type = "application/manifest+json"
            default: type = "text/html; charset=utf-8"
            }
            return Response(status: .ok, headers: [.contentType: type, .cacheControl: "no-store"], body: request.method == .head ? .init() : .init(byteBuffer: .init(bytes: data)))
        }
        do {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 6, parts[1] == "api", parts[2] == "v1", parts[3] == "accounts", !parts[4].isEmpty, parts[5] == "color" {
                guard request.method == .put else { return failure(.methodNotAllowed, Fault("method_not_allowed", "Use PUT to save an Account color.")) }
                let buffer = try await request.body.collect(upTo: 16_384)
                struct Input: Decodable { var index: Int }
                let input = try JSONDecoder().decode(Input.self, from: Data(buffer.readableBytesView))
                try await owner.setIdentityColor(accountID: String(parts[4]), index: input.index)
                return try json(await owner.snapshot())
            }
            if path == "/api/v1/pins" {
                guard request.method == .put else { return failure(.methodNotAllowed, Fault("method_not_allowed", "Use PUT to save pin order.")) }
                let buffer = try await request.body.collect(upTo: 16_384)
                struct Input: Decodable { var accountIds: [String] }
                let input = try JSONDecoder().decode(Input.self, from: Data(buffer.readableBytesView))
                try await owner.setPins(input.accountIds)
                return try json(await owner.snapshot())
            }
            if parts.count == 6, parts[1] == "api", parts[2] == "v1", parts[3] == "accounts", !parts[4].isEmpty, parts[5] == "redemptions" {
                guard request.method == .post else { return failure(.methodNotAllowed, Fault("method_not_allowed", "Use POST to submit a redemption.")) }
                let buffer = try await request.body.collect(upTo: 16_384)
                struct Input: Decodable {
                    var operationId: String
                    var creditId: String?
                    enum CodingKeys: String, CodingKey { case operationId, creditId }
                    init(from decoder: any Decoder) throws {
                        let fields = try decoder.container(keyedBy: CodingKeys.self)
                        operationId = try fields.decode(String.self, forKey: .operationId)
                        creditId = fields.contains(.creditId) ? try fields.decode(String.self, forKey: .creditId) : nil
                    }
                }
                let input = try JSONDecoder().decode(Input.self, from: Data(buffer.readableBytesView))
                let result = try await owner.submitRedemption(accountID: String(parts[4]), operationID: input.operationId, creditID: input.creditId)
                var response = try json(result, status: result.state == .pending ? .accepted : .ok)
                response.headers[.location] = result.resultUrl
                return response
            }
            if (parts.count == 5 || (parts.count == 6 && parts[5] == "acknowledge")), parts[1] == "api", parts[2] == "v1", parts[3] == "redemptions", !parts[4].isEmpty {
                if parts.count == 5 {
                    guard request.method == .get else { return failure(.methodNotAllowed, Fault("method_not_allowed", "Use GET to read a redemption.")) }
                    return try json(await owner.redemption(operationID: String(parts[4])))
                }
                guard request.method == .post else { return failure(.methodNotAllowed, Fault("method_not_allowed", "Use POST to acknowledge uncertainty.")) }
                let buffer = try await request.body.collect(upTo: 16_384)
                guard let object = try JSONSerialization.jsonObject(with: Data(buffer.readableBytesView)) as? [String: Any], object.isEmpty else {
                    throw Fault("invalid_request", "Acknowledgement requires an empty JSON object.")
                }
                return try json(await owner.acknowledgeRedemption(operationID: String(parts[4])))
            }
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
            let knownRead = path == "/api/v1/status" || path == "/api/v1/accounts" || path == "/api/v1/activity" ||
                (path.hasPrefix(detailPrefix) && !path.dropFirst(detailPrefix.count).contains("/") && path.count > detailPrefix.count)
            guard knownRead else { return failure(.notFound, Fault("not_found", "API route not found.")) }
            guard request.method == .get else { return failure(.methodNotAllowed, Fault("method_not_allowed", "Use GET for cached readings.")) }
            if path == "/api/v1/status" { return try json(await owner.snapshot().status) }
            if path == "/api/v1/accounts" { return try json(await owner.snapshot()) }
            if path == "/api/v1/activity" {
                let ranges = URLComponents(string: "http://localhost" + request.uri.string)?.queryItems?.filter { $0.name == "range" } ?? []
                guard ranges.count <= 1, let range = ActivityRange(rawValue: ranges.first.map { $0.value ?? "" } ?? "today") else {
                    return failure(.badRequest, Fault("invalid_request", "Choose today, yesterday, or last30days."))
                }
                return try json(await owner.activityResponse(range: range))
            }
            return try json(await owner.account(id: String(path.dropFirst(detailPrefix.count))))
        } catch let fault as Fault {
            let status: HTTPResponse.Status
            switch fault.code {
            case "invalid_request": status = .badRequest
            case "account_not_found", "operation_not_found": status = .notFound
            case "operation_conflict", "account_blocked": status = .conflict
            default: status = .serviceUnavailable
            }
            return failure(status, fault)
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
