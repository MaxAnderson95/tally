import CryptoKit
import Foundation
import HTTPTypes
import Hummingbird
import TallyCore
import WebAuthn

/// Password, passkey, and bearer-token authentication for the web UI and REST API (ADR 0002).
struct HTTPAuth: Sendable {
    enum Method: String { case cookie, token }

    static let cookieName = "tally_session"
    static let sessionTTL: TimeInterval = 30 * 24 * 3600

    let policy: HTTPPolicy
    let state: AuthState
    let codec: SessionCodec

    init(policy: HTTPPolicy, stateURL: URL) throws {
        guard !policy.password.isEmpty || !policy.token.isEmpty else {
            throw Fault("auth_unconfigured", "Set a web password or API token in Tally Settings to serve the web UI and API.")
        }
        self.policy = policy
        state = try AuthState(url: stateURL)
        codec = SessionCodec(key: SymmetricKey(data: state.signingKey))
    }

    /// A present Authorization header is the only credential considered, so a wrong token never falls back to a cookie.
    func authenticate(_ request: Request) -> Method? {
        if let header = request.headers[.authorization] {
            guard header.hasPrefix("Bearer "), !policy.token.isEmpty, constantTimeEqual(String(header.dropFirst(7)), policy.token) else { return nil }
            return .token
        }
        if let value = request.cookies[Self.cookieName]?.value, codec.verify(value, now: Date()) { return .cookie }
        return nil
    }

    /// Guards non-login routes. Cookie mutations must come from Tally's own page; bearer requests carry no ambient credentials.
    func reject(_ request: Request) -> Response? {
        switch authenticate(request) {
        case nil: failure(.unauthorized, Fault("unauthorized", "Authentication required."))
        case .cookie where isMutation(request) && !sameOrigin(request): failure(.forbidden, Fault("cross_origin", "Cross-origin request rejected."))
        default: nil
        }
    }

    func respond(to request: Request, path: String) async throws -> Response {
        let method = request.method
        func only(_ allowed: HTTPRequest.Method) -> Response? {
            method == allowed ? nil : failure(.methodNotAllowed, Fault("method_not_allowed", "Use \(allowed.rawValue) for \(path)."))
        }
        switch path {
        case "/api/v1/auth/state":
            if let wrong = only(.get) { return wrong }
            struct Output: Encodable { var passwordEnabled: Bool; var hasPasskeys: Bool }
            return try json(Output(passwordEnabled: !policy.password.isEmpty, hasPasskeys: await !state.passkeys().isEmpty))
        case "/api/v1/auth/me":
            if let wrong = only(.get) { return wrong }
            guard let method = authenticate(request) else { return failure(.unauthorized, Fault("unauthorized", "Authentication required.")) }
            struct Output: Encodable { var authenticated = true; var method: String }
            return try json(Output(method: method.rawValue))
        case "/api/v1/auth/login":
            if let wrong = only(.post) ?? loginOriginRejection(request) { return wrong }
            guard !policy.password.isEmpty else { return failure(.forbidden, Fault("password_disabled", "No web password is configured. Use the API token.")) }
            struct Input: Decodable { var password: String }
            let input = try await decode(Input.self, request)
            guard constantTimeEqual(input.password, policy.password) else {
                // One user: a flat delay is enough brute-force friction.
                try await Task.sleep(for: .milliseconds(500))
                return failure(.unauthorized, Fault("bad_password", "Wrong password."))
            }
            return session(try json(Ok()), request)
        case "/api/v1/auth/logout":
            // Logout needs no session so an expired cookie still clears, but another site must not sign the browser out.
            if let wrong = only(.post) ?? loginOriginRejection(request) { return wrong }
            var response = try json(Ok())
            response.setCookie(cookie("", maxAge: 0, request))
            return response
        case "/api/v1/auth/passkeys/login/begin":
            if let wrong = only(.post) ?? loginOriginRejection(request) { return wrong }
            let passkeys = await state.passkeys()
            guard !passkeys.isEmpty else { return failure(.notFound, Fault("no_passkeys", "No passkeys are registered.")) }
            let options = relyingParty(request).beginAuthentication(allowCredentials: passkeys.map { PublicKeyCredentialDescriptor(id: [UInt8]($0.credentialID)) })
            return try json(Ceremony(ceremonyId: await state.begin(options.challenge), options: options))
        case "/api/v1/auth/passkeys/login/finish":
            if let wrong = only(.post) ?? loginOriginRejection(request) { return wrong }
            struct Input: Decodable { var ceremonyId: String; var credential: AuthenticationCredential }
            let input = try await decode(Input.self, request)
            guard let challenge = await state.take(input.ceremonyId) else { return ceremonyExpired }
            guard let passkey = await state.passkeys().first(where: { $0.credentialID == Data(input.credential.rawID) }) else {
                return failure(.unauthorized, Fault("unknown_passkey", "This passkey is not registered with Tally."))
            }
            let verified: VerifiedAuthentication
            do {
                verified = try relyingParty(request).finishAuthentication(credential: input.credential, expectedChallenge: challenge,
                                                                          credentialPublicKey: [UInt8](passkey.publicKey), credentialCurrentSignCount: passkey.signCount)
            } catch { return failure(.unauthorized, Fault("passkey_rejected", "Passkey sign-in was not verified.")) }
            try? await state.used(passkey.credentialID, signCount: verified.newSignCount)
            return session(try json(Ok()), request)
        case "/api/v1/auth/passkeys":
            if let rejected = reject(request) ?? only(.get) { return rejected }
            struct Output: Encodable { var passkeys: [Passkey.Summary] }
            return try json(Output(passkeys: await state.passkeys().map(\.summary)))
        case "/api/v1/auth/passkeys/register/begin":
            if let rejected = reject(request) ?? only(.post) { return rejected }
            var options = relyingParty(request).beginRegistration(user: .init(id: [UInt8](state.userID), name: "tally", displayName: "Tally"))
            options.relyingParty = .init(id: options.relyingParty.id, name: "Tally")
            let excluded = await state.passkeys().map { PublicKeyCredentialDescriptor(id: [UInt8]($0.credentialID)) }
            return try json(Ceremony(ceremonyId: await state.begin(options.challenge), options: CreationOptions(base: options, excludeCredentials: excluded)))
        case "/api/v1/auth/passkeys/register/finish":
            if let rejected = reject(request) ?? only(.post) { return rejected }
            struct Input: Decodable { var ceremonyId: String; var name: String?; var credential: RegistrationCredential }
            let input = try await decode(Input.self, request)
            guard let challenge = await state.take(input.ceremonyId) else { return ceremonyExpired }
            let id = Data(input.credential.rawID)
            let registered = Set(await state.passkeys().map(\.credentialID))
            let credential: Credential
            do {
                credential = try await relyingParty(request).finishRegistration(challenge: challenge, credentialCreationData: input.credential,
                                                                                confirmCredentialIDNotRegisteredYet: { _ in !registered.contains(id) })
            } catch { return failure(.badRequest, Fault("passkey_rejected", "Passkey registration was not verified.")) }
            let name = input.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try await state.add(Passkey(credentialID: id, name: name.isEmpty ? "Passkey" : String(name.prefix(64)), publicKey: Data(credential.publicKey),
                                        signCount: credential.signCount, createdAt: Date()))
            return try json(Ok())
        default:
            let prefix = "/api/v1/auth/passkeys/"
            guard path.hasPrefix(prefix), !path.dropFirst(prefix.count).contains("/"), path.count > prefix.count else {
                return failure(.notFound, Fault("not_found", "API route not found."))
            }
            if let rejected = reject(request) ?? only(.delete) { return rejected }
            guard try await state.remove(String(path.dropFirst(prefix.count))) else { return failure(.notFound, Fault("unknown_passkey", "No passkey has that ID.")) }
            return try json(Ok())
        }
    }

    /// TLS ends before Tally (Tailscale Serve and OpenTunnel both forward plain HTTP to loopback), so the request cannot reveal
    /// its scheme. The allowlisted Host decides: the configured HTTPS origin's Host is HTTPS, and loopback Hosts are plain HTTP.
    private func isHTTPS(_ request: Request) -> Bool {
        policy.httpsAuthority != nil && request.head.authority?.lowercased() == policy.httpsAuthority
    }

    /// Passkeys are origin-bound, so each allowed origin is its own relying party. `127.0.0.1` cannot be one; browsers reject IP RP IDs.
    private func relyingParty(_ request: Request) -> WebAuthnManager {
        let authority = request.head.authority?.lowercased() ?? ""
        let host = authority.split(separator: ":").first.map(String.init) ?? authority
        let origin = (isHTTPS(request) ? "https://" : "http://") + authority
        return WebAuthnManager(configuration: .init(relyingPartyID: host, relyingPartyName: "Tally", relyingPartyOrigin: origin))
    }

    private func session(_ response: Response, _ request: Request) -> Response {
        var response = response
        response.setCookie(cookie(codec.mint(now: Date()), maxAge: Int(Self.sessionTTL), request))
        return response
    }

    private func cookie(_ value: String, maxAge: Int, _ request: Request) -> Cookie {
        Cookie(name: Self.cookieName, value: value, maxAge: maxAge, path: "/", secure: isHTTPS(request), httpOnly: true, sameSite: .strict)
    }

    /// Login endpoints accept header-less clients such as curl, but a browser request must come from Tally's own page.
    private func loginOriginRejection(_ request: Request) -> Response? {
        if request.headers[.origin] == nil && request.headers[secFetchSite] == nil { return nil }
        return sameOrigin(request) ? nil : failure(.forbidden, Fault("cross_origin", "Cross-origin request rejected."))
    }

    private var ceremonyExpired: Response { failure(.badRequest, Fault("ceremony_expired", "The passkey request expired. Start again.")) }

    private func decode<T: Decodable>(_ type: T.Type, _ request: Request) async throws -> T {
        let buffer = try await request.body.collect(upTo: 65_536)
        do { return try JSONDecoder().decode(type, from: Data(buffer.readableBytesView)) }
        catch { throw Fault("invalid_request", "Request body has the wrong shape.") }
    }
}

private struct Ok: Encodable { var ok = true }
private struct Ceremony<Options: Encodable>: Encodable { var ceremonyId: String; var options: Options }

/// webauthn-swift 1.0.0-beta.1 creation options have no excludeCredentials, which stops a browser re-registering one authenticator.
private struct CreationOptions: Encodable {
    var base: PublicKeyCredentialCreationOptions
    var excludeCredentials: [PublicKeyCredentialDescriptor]
    enum CodingKeys: CodingKey { case excludeCredentials }
    func encode(to encoder: any Encoder) throws {
        try base.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(excludeCredentials, forKey: .excludeCredentials)
    }
}

private let secFetchSite = HTTPField.Name("Sec-Fetch-Site")!

func isMutation(_ request: Request) -> Bool { ![.get, .head, .options].contains(request.method) }

/// Browsers send Origin or Sec-Fetch-Site on cross-origin requests. A request carrying neither did not come from a page.
func sameOrigin(_ request: Request) -> Bool {
    if let origin = request.headers[.origin] {
        guard let url = URL(string: origin), let host = url.host else { return false }
        return (host + (url.port.map { ":\($0)" } ?? "")).lowercased() == request.head.authority?.lowercased()
    }
    return ["same-origin", "none"].contains(request.headers[secFetchSite])
}

/// Hashing first makes the comparison independent of where the inputs differ and of their lengths.
private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    zip(SHA256.hash(data: Data(a.utf8)), SHA256.hash(data: Data(b.utf8))).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

/// Stateless signed sessions: base64url(payload) "." base64url(HMAC-SHA256(payload)). Restarting Tally keeps devices signed in.
struct SessionCodec: Sendable {
    let key: SymmetricKey
    private struct Payload: Codable { var iat: Int; var exp: Int; var n: String }

    func mint(now: Date) -> String {
        let payload = try! JSONEncoder().encode(Payload(iat: Int(now.timeIntervalSince1970), exp: Int(now.addingTimeInterval(HTTPAuth.sessionTTL).timeIntervalSince1970),
                                                        n: base64URL(Data(SymmetricKey(size: .init(bitCount: 64)).withUnsafeBytes { Data($0) }))))
        return base64URL(payload) + "." + base64URL(Data(HMAC<SHA256>.authenticationCode(for: payload, using: key)))
    }

    func verify(_ token: String, now: Date) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let payload = decodeBase64URL(parts[0]), let signature = decodeBase64URL(parts[1]),
              HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: payload, using: key),
              let decoded = try? JSONDecoder().decode(Payload.self, from: payload) else { return false }
        return now.timeIntervalSince1970 < TimeInterval(decoded.exp)
    }

    private func decodeBase64URL(_ text: Substring) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

struct Passkey: Codable, Sendable {
    var credentialID: Data
    var name: String
    var publicKey: Data
    var signCount: UInt32
    var createdAt: Date
    var lastUsedAt: Date?

    struct Summary: Encodable { var id: String; var name: String; var createdAt: Date; @Null var lastUsedAt: Date? }
    var summary: Summary { Summary(id: base64URL(credentialID), name: name, createdAt: createdAt, lastUsedAt: lastUsedAt) }
}

/// Machine-local auth state: the session signing key, the WebAuthn user handle, and registered passkeys. It lives beside
/// Tally's other Application Support data, is written owner-only, and must never be committed or synced.
actor AuthState {
    private struct File: Codable { var signingKey: Data; var userID: Data; var passkeys: [Passkey] }
    private let url: URL
    private var file: File
    private var ceremonies: [String: (challenge: [UInt8], expires: Date)] = [:]
    nonisolated let signingKey: Data
    nonisolated let userID: Data

    init(url: URL) throws {
        self.url = url
        let random = { Data(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }) }
        if let data = try? Data(contentsOf: url) {
            do { file = try JSONDecoder().decode(File.self, from: data) }
            catch { throw Fault("auth_state_unreadable", "Tally cannot read \(url.path). Fix or delete it; deleting it signs out every device and removes passkeys.") }
        } else {
            file = File(signingKey: random(), userID: random(), passkeys: [])
            try Self.write(file, to: url)
        }
        signingKey = file.signingKey; userID = file.userID
    }

    func passkeys() -> [Passkey] { file.passkeys }

    func add(_ passkey: Passkey) throws { file.passkeys.append(passkey); try persist() }

    func used(_ id: Data, signCount: UInt32) throws {
        guard let index = file.passkeys.firstIndex(where: { $0.credentialID == id }) else { return }
        file.passkeys[index].signCount = signCount
        file.passkeys[index].lastUsedAt = Date()
        try persist()
    }

    func remove(_ id: String) throws -> Bool {
        guard let index = file.passkeys.firstIndex(where: { base64URL($0.credentialID) == id }) else { return false }
        file.passkeys.remove(at: index)
        try persist()
        return true
    }

    /// Ceremonies are single-use and expire after five minutes; the unguessable ID is echoed back by the browser on finish.
    func begin(_ challenge: [UInt8]) -> String {
        let now = Date()
        ceremonies = ceremonies.filter { $0.value.expires > now }
        let id = base64URL(Data(SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }))
        ceremonies[id] = (challenge, now.addingTimeInterval(300))
        return id
    }

    func take(_ id: String) -> [UInt8]? {
        guard let ceremony = ceremonies.removeValue(forKey: id), ceremony.expires > Date() else { return nil }
        return ceremony.challenge
    }

    private func persist() throws { try Self.write(file, to: url) }

    private static func write(_ file: File, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.appendingPathExtension("tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: try JSONEncoder().encode(file), attributes: [.posixPermissions: 0o600]) else {
            throw Fault("auth_state_unwritable", "Tally cannot write \(url.path).")
        }
        guard rename(temporary.path, url.path) == 0 else { throw Fault("auth_state_unwritable", "Tally cannot write \(url.path).") }
    }
}
