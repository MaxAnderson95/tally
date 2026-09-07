import Foundation

struct AnthropicUsage: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileEndpoint = URL(string: "https://claude.ai/api/oauth/profile")!
    var session: URLSession = URLSession(configuration: .ephemeral)

    func job(access: String) -> CollectionJob {
        CollectionJob(id: "usage", groups: [.quotas, .extraUsage, .balances, .resetSummary, .resetDetails]) {
            try await collect(access: access)
        }
    }

    func planJob(access: String) -> CollectionJob {
        CollectionJob(id: "profile", groups: [.plan]) {
            [.plan(try Self.decodePlan(await request(Self.profileEndpoint, access: access)))]
        }
    }

    func collect(access: String) async throws -> [GroupObservation] {
        try Self.decode(await request(Self.endpoint, access: access))
    }

    private func request(_ endpoint: URL, access: String) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw Fault("provider_unavailable", "Anthropic could not be reached.") }
        guard let http = response as? HTTPURLResponse else { throw Fault("provider_unavailable", "Anthropic returned no HTTP response.") }
        guard http.statusCode == 200 else {
            var fault = Fault(http.statusCode == 401 ? "credentials_rejected" : "provider_unavailable",
                              "Anthropic request failed (HTTP \(http.statusCode)). Check the Account in OpenCode.")
            fault.retryAt = GoUsage.retryAfter(http.value(forHTTPHeaderField: "Retry-After"), at: Date())
            throw fault
        }
        return data
    }

    static func decodePlan(_ data: Data) throws -> Plan? {
        struct Profile: Decodable {
            struct Organization: Decodable { var organization_type: String? }
            var organization: Organization?
        }
        do {
            let keys = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard keys?["organization"] != nil || keys?["account"] != nil else { throw invalid() }
            let profile = try JSONDecoder().decode(Profile.self, from: data)
            guard let type = profile.organization?.organization_type, !type.isEmpty else { return nil }
            // Team can report a Max rate-limit tier. Only subscription organization type names the plan.
            let names = ["claude_team": "Team", "claude_pro": "Pro", "claude_max": "Max", "claude_enterprise": "Enterprise"]
            return Plan(name: names[type] ?? type)
        } catch { throw invalid() }
    }

    private struct Meter: Decodable { var utilization: Double?; var resets_at: Date? }
    private struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable { var id: String?; var display_name: String? }
            var model: Model?
            var surface: String?
        }
        var kind: String
        var group: String
        var percent: Double?
        var resets_at: Date?
        var scope: Scope?
    }
    private struct Amount: Decodable {
        var amount_minor: Decimal
        var currency: String
        var exponent: Int
        func money() throws -> Money {
            guard !currency.isEmpty, (0...12).contains(exponent), !amount_minor.isNaN else { throw invalid() }
            return Money(amount: "\(amount_minor / pow(10, exponent))", currency: currency,
                         source: Money.Source(amount: "\(amount_minor)", unit: "amount_minor", exponent: exponent))
        }
    }
    private struct Spend: Decodable { var enabled: Bool?; var used: Amount?; var limit: Amount? }
    private struct LegacySpend: Decodable {
        var is_enabled: Bool?
        var used_credits: Decimal?
        var monthly_limit: Decimal?
        var currency: String?
        var decimal_places: Int?
        func money(_ amount: Decimal?) throws -> Money? {
            guard let amount else { return nil }
            let exponent = decimal_places ?? 2
            let currency = currency ?? "USD"
            guard !amount.isNaN, (0...12).contains(exponent), !currency.isEmpty else { throw invalid() }
            return Money(amount: "\(amount / pow(10, exponent))", currency: currency,
                         source: Money.Source(amount: "\(amount)", unit: "legacy_credits", exponent: exponent))
        }
    }
    private struct Payload: Decodable {
        var five_hour: Meter?
        var seven_day: Meter?
        var seven_day_opus: Meter?
        var seven_day_sonnet: Meter?
        var limits: [Limit]?
        var spend: Spend?
        var extra_usage: LegacySpend?
    }

    private static func invalid() -> Fault { Fault("provider_response_invalid", "Anthropic returned malformed usage data.") }

    static func decode(_ data: Data) throws -> [GroupObservation] {
        do {
            let payload = try Wire.decoder().decode(Payload.self, from: data)
            // Reject unrelated successful JSON (including error envelopes), but accept explicit absence.
            let keys = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard keys?.keys.contains(where: { ["five_hour", "seven_day", "limits", "spend", "extra_usage"].contains($0) }) == true else { throw invalid() }
            var windows: [String: QuotaWindow] = [:]
            func window(id: String, label: String, cadence: String, duration: Double?, used: Double?, reset: Date?, model: String? = nil, modelID: String? = nil, surface: String? = nil) throws -> QuotaWindow {
                guard used?.isFinite ?? true else { throw invalid() }
                let fable = label.lowercased() == "fable" && model != nil && surface == nil
                return QuotaWindow(id: id, label: label, scope: surface != nil ? "other" : model == nil ? "account" : "model",
                                   scopeNote: fable ? "Fable can use up to half of the weekly allowance. This is a scoped suballowance, not additional weekly capacity." : surface,
                                   modelId: modelID, cadence: cadence, durationSeconds: duration,
                                   durationSource: duration == nil ? "unknown" : "verified_mapping", usedPercent: used, resetAt: reset,
                                   displayInOverview: (model == nil && surface == nil) || fable)
            }
            for (id, label, meter, model, duration) in [
                ("session", "5-hour", payload.five_hour, nil, 18_000.0),
                ("weekly_all", "Weekly", payload.seven_day, nil, 604_800.0),
                ("weekly_scoped:opus", "Opus", payload.seven_day_opus, "opus", 604_800.0),
                ("weekly_scoped:sonnet", "Sonnet", payload.seven_day_sonnet, "sonnet", 604_800.0)
            ] {
                if let meter { windows[id] = try window(id: id, label: label, cadence: duration == 18_000 ? "rolling" : "weekly", duration: duration, used: meter.utilization, reset: meter.resets_at, model: model) }
            }
            for limit in payload.limits ?? [] {
                let model = limit.scope?.model?.id ?? limit.scope?.model?.display_name?.lowercased()
                let surface = limit.scope?.surface
                // A scoped meter without an identifiable scope cannot safely become account-wide.
                if (limit.kind == "weekly_scoped" || limit.scope != nil) && model == nil && surface == nil { continue }
                let id = limit.kind + (model.map { ":\($0)" } ?? "") + (surface.map { ":surface:\($0)" } ?? "")
                let duration: Double? = limit.kind == "session" ? 18_000 : limit.group == "weekly" ? 604_800 : nil
                let label = limit.scope?.model?.display_name ?? surface ?? (limit.kind == "session" ? "5-hour" : limit.kind == "weekly_all" ? "Weekly" : limit.kind)
                windows[id] = try window(id: id, label: label, cadence: duration == 18_000 ? "rolling" : duration == 604_800 ? "weekly" : "other", duration: duration, used: limit.percent, reset: limit.resets_at, model: model, modelID: limit.scope?.model?.id, surface: surface)
            }
            var extra: ExtraUsage?
            if let spend = payload.spend {
                extra = try ExtraUsage(enabled: spend.enabled, used: spend.used?.money(), limit: spend.limit?.money())
            } else if let spend = payload.extra_usage {
                extra = try ExtraUsage(enabled: spend.is_enabled, used: spend.money(spend.used_credits), limit: spend.money(spend.monthly_limit), periodLabel: "Monthly")
            }
            extra?.derive()
            return [.quotas(Quotas(windows: windows.values.sorted {
                if $0.durationSeconds != $1.durationSeconds { return ($0.durationSeconds ?? .infinity) < ($1.durationSeconds ?? .infinity) }
                return $0.id < $1.id
            })), .extraUsage(extra), .balances(nil), .resetSummary(nil), .resetDetails(nil)]
        } catch { throw invalid() }
    }
}
