import Foundation

struct GoObservation: Sendable { var windows: [QuotaWindow] }

struct GoUsage: Sendable {
    static let endpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    var session: URLSession = URLSession(configuration: .ephemeral)

    func collect(key: String) async throws -> GoObservation {
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw Fault("provider_unavailable", "OpenCode Go could not be reached.") }
        guard let http = response as? HTTPURLResponse else { throw Fault("provider_unavailable", "OpenCode Go returned no HTTP response.") }
        guard http.statusCode == 200 else {
            var fault: Fault
            switch http.statusCode {
            case 401: fault = Fault("credentials_rejected", "OpenCode Go rejected this key. Check the Account in OpenCode.")
            case 403: fault = Fault("entitlement_unavailable", "OpenCode Go entitlement could not be verified.")
            default: fault = Fault("provider_unavailable", "OpenCode Go usage request failed (HTTP \(http.statusCode)).")
            }
            fault.retryAt = Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After"), at: Date())
            throw fault
        }
        return try Self.decode(data)
    }

    static func retryAfter(_ header: String?, at now: Date) -> Date? {
        guard let header else { return nil }
        if let seconds = Double(header), seconds.isFinite, seconds >= 0 {
            let date = now.addingTimeInterval(seconds)
            return date.timeIntervalSince1970.isFinite ? date : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header).flatMap { $0 > now ? $0 : nil }
    }

    static func decode(_ data: Data) throws -> GoObservation {
        struct Meter: Decodable { var status: String?; var percent: Double?; var resetsAt: String? }
        struct Payload: Decodable { var usage: [String: Meter] }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw Fault("provider_response_invalid", "OpenCode Go returned malformed usage data.") }
        let mappings: [(String, String, String, Double?)] = [
            ("rolling", "5-hour", "rolling", 18_000), ("weekly", "Weekly", "weekly", 604_800), ("monthly", "Monthly", "monthly", nil)
        ]
        let windows = try mappings.compactMap { id, label, cadence, duration -> QuotaWindow? in
            guard let meter = payload.usage[id] else { return nil }
            if let status = meter.status, status != "ok" && status != "rate-limited" {
                throw Fault("provider_response_invalid", "OpenCode Go returned an unrecognized meter status.")
            }
            guard meter.percent?.isFinite ?? true else { throw Fault("provider_response_invalid", "OpenCode Go returned a non-finite percentage.") }
            var reset: Date?
            if let text = meter.resetsAt {
                reset = try? Date(text, strategy: .iso8601)
                if reset == nil {
                    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    reset = formatter.date(from: text)
                }
                guard reset != nil else { throw Fault("provider_response_invalid", "OpenCode Go returned an invalid reset instant.") }
            }
            return QuotaWindow(id: id, label: label, cadence: cadence, durationSeconds: duration,
                               durationSource: duration == nil ? "unknown" : "verified_mapping", usedPercent: meter.percent, resetAt: reset)
        }
        return GoObservation(windows: windows)
    }
}
