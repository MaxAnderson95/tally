import Foundation
import Network

struct ResetHTTPResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data
}

struct OpenAIRedemption: Sendable {
    var transport: @Sendable (URLRequest) async throws -> ResetHTTPResponse = { try await SingleSendHTTP.send($0) }

    func credits(_ credential: StoredCredential) async throws -> ResetDetails {
        let response = try await transport(request(credential, credit: nil, operation: nil))
        guard response.status == 200 else {
            var fault = Fault([401, 403].contains(response.status) ? "credentials_rejected" : "provider_unavailable", "OpenAI credit preflight failed (HTTP \(response.status)).")
            fault.retryAt = GoUsage.retryAfter(response.headers["retry-after"], at: Date())
            throw fault
        }
        return try OpenAIUsage.decodeCredits(response.body)
    }

    func consume(_ credential: StoredCredential, credit: String, operation: String) async throws -> Redemption.ProviderResult {
        let response = try await transport(request(credential, credit: credit, operation: operation))
        // No documented non-200 response proves this invocation did not consume a credit.
        guard response.status == 200 else {
            var fault = Fault([401, 403].contains(response.status) ? "credentials_rejected" : "provider_response_unknown", "OpenAI did not return a definitive consume result.")
            fault.retryAt = GoUsage.retryAfter(response.headers["retry-after"], at: Date())
            throw fault
        }
        struct Payload: Decodable { var code: String; var windows_reset: Int? }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: response.body),
              ["reset", "already_redeemed", "nothing_to_reset", "no_credit"].contains(payload.code),
              payload.windows_reset.map({ $0 >= 0 }) ?? true else {
            throw Fault("provider_response_unknown", "OpenAI returned an unrecognized consume result.")
        }
        return Redemption.ProviderResult(code: payload.code, windowsReset: payload.windows_reset)
    }

    func request(_ credential: StoredCredential, credit: String?, operation: String?) throws -> URLRequest {
        guard let workspace = credential.workspace, !workspace.isEmpty, !credential.key.isEmpty else {
            throw Fault("credentials_unavailable", "OpenCode has not supplied this Account's credential and workspace.")
        }
        var request = URLRequest(url: credit == nil ? OpenAIUsage.creditsEndpoint : OpenAIUsage.creditsEndpoint.appendingPathComponent("consume"))
        request.httpMethod = credit == nil ? "GET" : "POST"
        request.timeoutInterval = credit == nil ? 10 : 15
        request.setValue("Bearer \(credential.key)", forHTTPHeaderField: "Authorization")
        request.setValue(workspace, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let credit, let operation {
            struct Body: Encodable { var credit_id: String; var redeem_request_id: String }
            request.httpBody = try JSONEncoder().encode(Body(credit_id: credit, redeem_request_id: operation))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}

// A single TLS connection and one application-data write. No redirect, authentication,
// connection replacement, HTTP retry, or provider replay machinery can resend this POST.
final class SingleSendHTTP: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Tally.single-send")
    private let connection: NWConnection
    private var continuation: CheckedContinuation<ResetHTTPResponse, Error>?
    private var finished = false
    private var sent = false
    private var received = Data()

    private init(host: String) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: 443, using: .tls)
    }

    static func send(_ request: URLRequest) async throws -> ResetHTTPResponse {
        guard let url = request.url, url.scheme == "https", let host = url.host, url.port == nil else { throw invalid() }
        let bytes = try encode(request)
        let exchange = SingleSendHTTP(host: host)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                exchange.queue.async {
                    if exchange.finished { continuation.resume(throwing: CancellationError()); return }
                    exchange.continuation = continuation
                    exchange.connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            guard !exchange.sent, !exchange.finished else { return }
                            exchange.sent = true
                            exchange.connection.send(content: bytes, completion: .contentProcessed { error in
                                if let error { exchange.finish(.failure(error)) }
                                else { exchange.receive() }
                            })
                        case .failed(let error): exchange.finish(.failure(error))
                        case .cancelled: exchange.finish(.failure(CancellationError()))
                        default: break
                        }
                    }
                    exchange.queue.asyncAfter(deadline: .now() + request.timeoutInterval) {
                        exchange.finish(.failure(URLError(.timedOut)))
                    }
                    exchange.connection.start(queue: exchange.queue)
                }
            }
        } onCancel: {
            exchange.queue.async { exchange.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<ResetHTTPResponse, Error>) {
        guard !finished else { return }
        finished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(with: result); continuation = nil
    }

    private func receive() {
        guard !finished else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            if let error { self.finish(.failure(error)); return }
            if let data { self.received.append(data) }
            do {
                if let response = try Self.decode(self.received, complete: complete) { self.finish(.success(response)) }
                else { self.receive() }
            } catch { self.finish(.failure(error)) }
        }
    }

    private static func invalid() -> Fault { Fault("provider_response_unknown", "The one-shot provider exchange did not complete with a valid HTTP response.") }

    static func encode(_ request: URLRequest) throws -> Data {
        guard let url = request.url, let host = url.host, let method = request.httpMethod else { throw invalid() }
        var headers = request.allHTTPHeaderFields ?? [:]
        headers["Host"] = host; headers["Connection"] = "close"; headers["Accept-Encoding"] = "identity"
        headers["Content-Length"] = String(request.httpBody?.count ?? 0)
        guard headers.allSatisfy({ key, value in
            !key.isEmpty && (key + value).unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 }
        }) else { throw invalid() }
        let path = url.path + (url.query.map { "?" + $0 } ?? "")
        var data = Data(("\(method) \(path) HTTP/1.1\r\n" + headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n").utf8)
        data.append(request.httpBody ?? Data())
        return data
    }

    static func decode(_ data: Data, complete: Bool) throws -> ResetHTTPResponse? {
        guard data.count <= 1_048_576 else { throw invalid() }
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
            if complete || data.count > 16_384 { throw invalid() }; return nil
        }
        guard split.lowerBound <= 16_384, let text = String(data: data[..<split.lowerBound], encoding: .utf8) else { throw invalid() }
        let lines = text.components(separatedBy: "\r\n")
        let statusLine = lines[0].split(separator: " ")
        guard statusLine.count >= 2, ["HTTP/1.1", "HTTP/1.0"].contains(statusLine[0]), let status = Int(statusLine[1]), (200...599).contains(status) else { throw invalid() }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw invalid() }
            let key = line[..<colon].lowercased()
            if headers[key] != nil {
                guard !["content-length", "transfer-encoding", "content-encoding"].contains(key) else { throw invalid() }
                continue
            }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["content-encoding"].map({ $0 == "identity" }) ?? true else { throw invalid() }
        let body = Data(data[split.upperBound...])
        if let transfer = headers["transfer-encoding"] {
            guard transfer.lowercased() == "chunked", headers["content-length"] == nil else { throw invalid() }
            var cursor = 0
            var decoded = Data()
            while cursor < body.count {
                guard let end = body.range(of: Data("\r\n".utf8), in: cursor..<body.count),
                      let line = String(data: body[cursor..<end.lowerBound], encoding: .utf8),
                      let digits = line.split(separator: ";", maxSplits: 1).first,
                      let length = Int(digits, radix: 16), length >= 0, length <= 1_048_576 else {
                    if complete { throw invalid() }; return nil
                }
                cursor = end.upperBound
                guard body.count - cursor >= length + 2 else { if complete { throw invalid() }; return nil }
                guard body[cursor + length..<cursor + length + 2] == Data("\r\n".utf8) else { throw invalid() }
                if length == 0 {
                    guard cursor + 2 == body.count else { throw invalid() }
                    return ResetHTTPResponse(status: status, headers: headers, body: decoded)
                }
                decoded.append(body[cursor..<cursor + length]); cursor += length + 2
            }
        } else if let text = headers["content-length"] {
            guard let length = Int(text), length >= 0, length <= 1_048_576, body.count <= length else { throw invalid() }
            if body.count == length { return ResetHTTPResponse(status: status, headers: headers, body: body) }
        } else if complete { return ResetHTTPResponse(status: status, headers: headers, body: body) }
        if complete { throw invalid() }
        return nil
    }
}
