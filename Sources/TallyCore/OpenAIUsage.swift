import Foundation

struct OpenAIUsage: Sendable {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let creditsEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    var session: URLSession = URLSession(configuration: .ephemeral)

    func jobs(access: String, workspace: String?) -> [CollectionJob] {
        [CollectionJob(id: "usage", groups: [.plan, .quotas, .extraUsage, .balances, .resetSummary]) {
            try Self.decodeUsage(await request(Self.endpoint, access: access, workspace: workspace), at: Date())
        }, CollectionJob(id: "reset-credits", groups: [.resetDetails]) {
            [.resetDetails(try Self.decodeCredits(await request(Self.creditsEndpoint, access: access, workspace: workspace)))]
        }]
    }

    private func request(_ endpoint: URL, access: String, workspace: String?) async throws -> Data {
        guard let workspace, !workspace.isEmpty else { throw Fault("credentials_unavailable", "OpenCode has not supplied this Account's workspace.") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue(workspace, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw Fault("provider_unavailable", "OpenAI could not be reached.") }
        guard let http = response as? HTTPURLResponse else { throw Fault("provider_unavailable", "OpenAI returned no HTTP response.") }
        guard http.statusCode == 200 else {
            var fault = Fault(http.statusCode == 401 ? "credentials_rejected" : "provider_unavailable", "OpenAI request failed (HTTP \(http.statusCode)). Check the Account in OpenCode.")
            fault.retryAt = GoUsage.retryAfter(http.value(forHTTPHeaderField: "Retry-After"), at: Date())
            throw fault
        }
        return data
    }

    private struct Window: Decodable {
        var used_percent: Double?
        var limit_window_seconds: Double?
        var reset_at: Double?
        var reset_after_seconds: Double?
    }
    private struct Limit: Decodable { var primary_window: Window?; var secondary_window: Window? }
    private struct Additional: Decodable { var limit_name: String; var metered_feature: String; var rate_limit: Limit?; var normal_model_slug: String? }
    private struct Purchased: Decodable { var balance: String?; var has_credits: Bool?; var unlimited: Bool? }
    private struct Summary: Decodable {
        var available_count: Int?
        var applicable_available_count: Int?
        func normalized(source: String) throws -> ResetSummary {
            guard available_count.map({ $0 >= 0 }) ?? true, applicable_available_count.map({ $0 >= 0 }) ?? true else { throw invalid() }
            return ResetSummary(availableCount: available_count, applicableAvailableCount: applicable_available_count, source: source)
        }
    }
    private struct Usage: Decodable {
        var plan_type: String?
        var rate_limit: Limit?
        var additional_rate_limits: [Additional]?
        var credits: Purchased?
        var rate_limit_reset_credits: Summary?
    }
    private static func invalid() -> Fault { Fault("provider_response_invalid", "OpenAI returned malformed reading data.") }

    static func decodeUsage(_ data: Data, at now: Date) throws -> [GroupObservation] {
        do {
            let keys = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard keys?.keys.contains(where: { ["rate_limit", "additional_rate_limits", "credits", "plan_type"].contains($0) }) == true else { throw invalid() }
            let payload = try JSONDecoder().decode(Usage.self, from: data)
            var windows: [QuotaWindow] = []
            func append(_ limit: Limit?, prefix: String, name: String? = nil, model: String? = nil) throws {
                for (slot, meter) in [("primary", limit?.primary_window), ("secondary", limit?.secondary_window)] {
                    guard let meter else { continue }
                    let duration = meter.limit_window_seconds.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
                    let label = duration == 604_800 ? "Weekly" : duration == 18_000 ? "5-hour" : duration.map { "\($0.formatted(.number.grouping(.never).precision(.fractionLength(0)).locale(Locale(identifier: "en_US_POSIX"))))-second" } ?? slot.capitalized
                    let reset = meter.reset_at.map(Date.init(timeIntervalSince1970:)) ?? meter.reset_after_seconds.map { now.addingTimeInterval($0) }
                    windows.append(QuotaWindow(id: "\(prefix):\(slot)", label: name.map { "\($0) \(label)" } ?? label,
                                               scope: name == nil ? "account" : model == nil ? "other" : "model", modelId: model,
                                               cadence: duration == 604_800 ? "weekly" : duration == 18_000 ? "rolling" : "other",
                                               durationSeconds: duration, durationSource: duration == nil ? "unknown" : "provider",
                                               usedPercent: meter.used_percent, resetAt: reset, displayInOverview: name == nil))
                }
            }
            try append(payload.rate_limit, prefix: "rate_limit")
            for additional in payload.additional_rate_limits ?? [] {
                try append(additional.rate_limit, prefix: "additional:\(additional.metered_feature):\(additional.limit_name)", name: additional.limit_name, model: additional.normal_model_slug)
            }
            var balances: Balances?
            if let credits = payload.credits {
                let quantity: Decimal?
                if let balance = credits.balance {
                    guard balance.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
                          let parsed = Decimal(string: balance, locale: Locale(identifier: "en_US_POSIX")), !parsed.isNaN else { throw invalid() }
                    quantity = parsed
                } else { quantity = credits.has_credits == false && credits.unlimited != true ? 0 : nil }
                let reference = quantity.map { Money(amount: "\($0 * Decimal(string: "0.04")!)", currency: "USD", provenance: "reference_conversion", source: Money.Source(amount: "\($0)", unit: "credits", exponent: nil)) }
                balances = Balances(items: [Balance(unit: "credits", quantity: quantity.map { "\($0)" }, referenceValue: reference, unlimited: credits.unlimited)])
            }
            let plans = ["plus": "Plus", "pro": "Pro 20x", "prolite": "Pro 5x", "self_serve_business_prolite": "Business Premium"]
            let plan = payload.plan_type.flatMap { $0.isEmpty ? nil : Plan(name: plans[$0] ?? $0) }
            windows.sort { $0.durationSeconds != $1.durationSeconds ? ($0.durationSeconds ?? .infinity) < ($1.durationSeconds ?? .infinity) : $0.id < $1.id }
            guard Set(windows.map(\.id)).count == windows.count else { throw invalid() }
            let quotas = keys?["rate_limit"] == nil ? nil : Quotas(windows: windows)
            return [.plan(plan), .quotas(quotas), .extraUsage(nil), .balances(balances), .resetSummary(try payload.rate_limit_reset_credits?.normalized(source: "usage"))]
        } catch { throw invalid() }
    }

    private struct RawCredit: Decodable {
        var id: String
        var reset_type: String?
        var status: String?
        var title: String?
        var description: String?
        var granted_at: Date?
    }
    static func decodeCredits(_ data: Data) throws -> ResetDetails {
        do {
            struct Payload: Decodable { var credits: [RawCredit]; var available_count: Int?; var applicable_available_count: Int? }
            let payload = try Wire.decoder().decode(Payload.self, from: data)
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let rows = raw?["credits"] as? [[String: Any]] ?? []
            let credits = try payload.credits.enumerated().map { index, credit in
                guard !credit.id.isEmpty else { throw invalid() }
                let rawExpiry = rows[index]["expires_at"]
                let date = (rawExpiry as? String).flatMap { text -> Date? in
                    let encoded = try? JSONEncoder().encode(text)
                    return encoded.flatMap { try? Wire.decoder().decode(Date.self, from: $0) }
                }
                let expiry = date.map { Credit.Expiry(kind: "at", at: $0) } ?? Credit.Expiry(kind: rawExpiry is NSNull ? "none" : "unknown")
                let available: Bool? = credit.status == "available" ? true : ["redeemed", "expired", "redeeming"].contains(credit.status ?? "") ? false : nil
                return Credit(id: credit.id, type: credit.reset_type, status: credit.status, available: available, title: credit.title, description: credit.description, grantedAt: credit.granted_at, expiry: expiry)
            }.sorted { $0.id < $1.id }
            guard Set(credits.map(\.id)).count == credits.count else { throw invalid() }
            return ResetDetails(credits: credits, summary: try Summary(available_count: payload.available_count, applicable_available_count: payload.applicable_available_count).normalized(source: "credit_details"))
        } catch { throw invalid() }
    }
}
