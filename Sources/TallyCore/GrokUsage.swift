import Foundation

struct GrokUsage: Sendable {
    static let endpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    static let settingsEndpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    var session: URLSession = URLSession(configuration: .ephemeral)

    func jobs(access: String) -> [CollectionJob] {
        [CollectionJob(id: "billing", groups: [.quotas, .extraUsage, .balances, .resetSummary, .resetDetails]) {
            try Self.decode(await request(Self.endpoint, access: access))
        }, CollectionJob(id: "settings", groups: [.plan]) {
            [.plan(try Self.decodePlan(await request(Self.settingsEndpoint, access: access)))]
        }]
    }

    private func request(_ endpoint: URL, access: String) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw Fault("provider_unavailable", "Grok could not be reached.") }
        guard let http = response as? HTTPURLResponse else { throw Fault("provider_unavailable", "Grok returned no HTTP response.") }
        guard http.statusCode == 200 else {
            // Optional settings access can be rejected while the same token still reads billing.
            var fault = Fault(http.statusCode == 401 && endpoint == Self.endpoint ? "credentials_rejected" : "provider_unavailable",
                              "Grok request failed (HTTP \(http.statusCode)). Check the Account in OpenCode.")
            fault.retryAt = GoUsage.retryAfter(http.value(forHTTPHeaderField: "Retry-After"), at: Date())
            throw fault
        }
        return data
    }

    private struct Amount: Decodable {
        var val: Decimal?
        func money() throws -> Money? {
            guard let val else { return nil }
            guard !val.isNaN, val >= 0 else { throw invalid() }
            // format=credits reports credit units, not dollars. No currency conversion is established.
            return Money(amount: "\(val)", currency: "credits", source: Money.Source(amount: "\(val)", unit: "credits"))
        }
    }
    private struct Period: Decodable { var type: String; var start: Date; var end: Date }
    private struct Config: Decodable {
        var currentPeriod: Period
        var creditUsagePercent: Double?
        var onDemandCap: Amount?
        var onDemandUsed: Amount?
    }
    private struct Payload: Decodable { var config: Config }
    private static func invalid() -> Fault { Fault("provider_response_invalid", "Grok returned malformed billing or settings data.") }

    static func decode(_ data: Data) throws -> [GroupObservation] {
        do {
            let config = try Wire.decoder().decode(Payload.self, from: data).config
            let period = config.currentPeriod
            guard !period.type.isEmpty, period.end > period.start else { throw invalid() }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let fields = object?["config"] as? [String: Any]
            // Only a structurally compatible credits config gets proto3's omitted-percent zero.
            // Explicit null is malformed, and no other omitted billing field becomes zero.
            guard fields?["creditUsagePercent"] == nil || config.creditUsagePercent != nil else { throw invalid() }
            let used = config.creditUsagePercent ?? 0
            guard used.isFinite else { throw invalid() }
            let cap = try config.onDemandCap?.money()
            var extra = ExtraUsage(enabled: config.onDemandCap?.val.map { $0 > 0 }, used: try config.onDemandUsed?.money(), limit: cap)
            extra.derive()
            let windows = period.type == "USAGE_PERIOD_TYPE_WEEKLY" ? [
                QuotaWindow(id: "weekly", label: "Weekly", cadence: "weekly", durationSeconds: period.end.timeIntervalSince(period.start),
                            durationSource: "provider", usedPercent: used, resetAt: period.end)
            ] : []
            return [.quotas(Quotas(windows: windows)), .extraUsage(extra), .balances(nil), .resetSummary(nil), .resetDetails(nil)]
        } catch { throw invalid() }
    }

    static func decodePlan(_ data: Data) throws -> Plan? {
        struct Settings: Decodable { var subscription_tier_display: String? }
        do {
            let settings = try JSONDecoder().decode(Settings.self, from: data)
            guard let name = settings.subscription_tier_display?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            return Plan(name: name)
        } catch { throw invalid() }
    }
}
