import Foundation

public enum ActivityRange: String, Codable, Sendable, CaseIterable {
    case today, yesterday, last30days
    public var label: String { switch self { case .today: "Today"; case .yesterday: "Yesterday"; case .last30days: "Last 30 days" } }
}

public struct Tokens: Codable, Sendable {
    public var input: Double = 0
    public var output: Double = 0
    public var reasoning: Double = 0
    public var cacheRead: Double = 0
    public var cacheWrite: Double = 0
    public var total: Double = 0
    mutating func add(_ value: Tokens) {
        input += value.input; output += value.output; reasoning += value.reasoning
        cacheRead += value.cacheRead; cacheWrite += value.cacheWrite
        total = input + output + reasoning + cacheRead + cacheWrite
    }
}
public struct PricingCoverage: Codable, Sendable {
    public var fullyPricedRows = 0
    public var boundedRows = 0
    public var partiallyPricedRows = 0
    public var unpricedRows = 0
    public var missingUsageRows = 0
    public var pricedComponents = Tokens()
    public var unpricedComponents = Tokens()
}
public struct PricingExclusion: Codable, Sendable {
    public var provider: String
    public var modelId: String
    public var reason: String
    public var rows: Int
    @Null public var tokens: Tokens?
}
public struct Estimate: Codable, Sendable {
    public var status = "empty"
    public var currency = "USD"
    @Null public var lower: String? = "0"
    @Null public var upper: String? = "0"
    public var coverage = PricingCoverage()
    public var exclusions: [PricingExclusion] = []
}
public struct RecordedCost: Codable, Sendable {
    @Null public var amount: String? = nil
    public var currency = "USD"
    public var rowsWithCost = 0
    public var missingCostRows = 0
    public var ambiguousZeroRows = 0
}
public struct ActivityAggregate: Codable, Sendable {
    public var rows = 0
    public var missingUsageRows = 0
    @Null public var tokens: Tokens? = Tokens()
    public var recordedCost = RecordedCost()
    public var estimate = Estimate()
    public var tokenLabel: String {
        rows == 0 ? "No recorded activity" : tokens.map { "\($0.total.formatted()) recorded tokens" } ?? "Usage missing"
    }
    public var costLabel: String {
        if rows == 0 { return "Recorded cost: no recorded activity" }
        guard let amount = recordedCost.amount else { return "Recorded cost unavailable" }
        return amount == "0" ? "Recorded $0; pricing provenance unknown" : "Recorded $\(amount) USD"
    }
}
public struct ActivitySource: Codable, Sendable {
    public var namespaceId: String
    public var schemaRevision = "opencode-v2-assistant-1"
    public var attribution = "provider_local_database"
    public var partialHistory = true
    public var qualifications = [
        "Partial history from this Mac's OpenCode records; provider/local-database attribution, never current Accounts.",
        "Deletes and reverts can lower totals. Imports need not have executed on this Mac. Known fork prefixes are excluded, including copies whose parents were deleted; unidentified historical copies may remain.",
        "Missing final usage is not zero. Title and compaction calls without provider/model attribution are not allocated. V1 remnants, events, and session totals are not added.",
        "OpenCode Go provider activity uses the recorded provider label; routing overrides and prepaid fallback mean it does not prove Go quota billing. Zen is excluded.",
        "Five recorded components are summed once. Upstream normalization may hide omitted components; finite negative historical values are preserved, not corrected or independently audited. Recorded cost uses OpenCode runtime pricing, not provider charges; recorded zeros have unknown pricing provenance.",
        "API-equivalent estimates use dated standard synchronous/global reference-token rates, not subscription charges, historical bills, quota consumption, savings or actual fees. Non-token fees are excluded. Recorded cost never substitutes for an estimate.",
        "Anthropic writes use verified 5m/1h bounds; Go DeepSeek uses off-peak/peak bounds, without inferred duration or server pricing time. Partial bounds cover priced components only and do not bound all activity. Negative historical components invalidate pricing reconstruction; signed records remain visible and unpriced."
    ]
    @Null public var firstRetainedAt: Date?
    @Null public var lastRetainedAt: Date?
    public var populatedDays: Int
}
public struct ActivityPricing: Codable, Sendable {
    public var revision = ActivityPrices.bundled?.revision ?? "bundle-unavailable"
    public var observedOn = ActivityPrices.bundled?.observedOn ?? "unknown"
    public var digest = ActivityPrices.digest
    public var basis = "standard_global_api_equivalent"
}
public struct ActivityModel: Codable, Sendable { public var modelId: String; public var totals: ActivityAggregate }
public struct ActivityProvider: Codable, Sendable {
    public var provider: String
    public var label: String
    public var totals: ActivityAggregate
    public var models: [ActivityModel]
}
public struct ActivityDay: Codable, Sendable {
    public var date: String
    public var startAt: Date
    public var endAt: Date
    public var selected: Bool
    public var totals: ActivityAggregate
}
public struct ActivityTrend: Codable, Sendable {
    public var range = ActivityRange.last30days
    public var startAt: Date
    public var endAt: Date
    public var days: [ActivityDay]
}
public struct ActivityData: Codable, Sendable {
    public var range: ActivityRange
    public var startAt: Date
    public var endAt: Date
    public var timezone: String
    public var source: ActivitySource
    public var pricing = ActivityPricing()
    public var totals: ActivityAggregate
    public var providers: [ActivityProvider]
    public var trend: ActivityTrend
}
public struct ActivityResponse: Codable, Sendable { public var status: Status; public var activity: Group<ActivityData> }

struct ActivityRow: Sendable {
    var created: Date
    var provider: String
    var model: String
    var tokens: Tokens?
    var cost: Decimal?
}

struct ActivityScan: Sendable {
    var databaseIdentity: String
    var rows: [ActivityRow]

    func derive(namespace: String, cutoff: Date, timezone: TimeZone) -> [String: ActivityData] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
        let today = calendar.startOfDay(for: cutoff)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = timezone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let retained = rows.filter { $0.created < cutoff && providerOrder.contains($0.provider) }
        let source = ActivitySource(namespaceId: namespace, firstRetainedAt: retained.map(\.created).min(),
                                    lastRetainedAt: retained.map(\.created).max(), populatedDays: Set(retained.map { formatter.string(from: $0.created) }).count)
        let days = (-29...0).map { offset in
            let start = day(offset), end = min(day(offset + 1), cutoff)
            return ActivityDay(date: formatter.string(from: start), startAt: start, endAt: end, selected: false,
                               totals: aggregate(retained.filter { $0.created >= start && $0.created < end }))
        }
        return Dictionary(uniqueKeysWithValues: ActivityRange.allCases.map { range in
            let start = range == .last30days ? day(-29) : range == .yesterday ? day(-1) : today
            let end = range == .yesterday ? today : cutoff
            let selected = retained.filter { $0.created >= start && $0.created < end }
            let providers = providerOrder.compactMap { provider -> ActivityProvider? in
                let rows = selected.filter { $0.provider == provider }
                guard !rows.isEmpty else { return nil }
                let models = Set(rows.map(\.model)).sorted().map { model in ActivityModel(modelId: model, totals: aggregate(rows.filter { $0.model == model })) }
                return ActivityProvider(provider: provider, label: provider == "opencode-go" ? "OpenCode Go provider activity" : provider, totals: aggregate(rows), models: models)
            }
            let trend = ActivityTrend(startAt: day(-29), endAt: cutoff, days: days.map { original in
                var value = original
                value.selected = range == .last30days || (range == .today ? value.startAt == today : value.startAt == day(-1))
                return value
            })
            return (range.rawValue, ActivityData(range: range, startAt: start, endAt: end, timezone: timezone.identifier, source: source,
                                                totals: aggregate(selected), providers: providers, trend: trend))
        })
    }
}

private func aggregate(_ rows: [ActivityRow]) -> ActivityAggregate {
    var result = ActivityAggregate(); result.rows = rows.count
    result.missingUsageRows = rows.filter { $0.tokens == nil }.count
    result.tokens = rows.isEmpty || result.missingUsageRows < rows.count ? Tokens() : nil
    var cost = Decimal.zero
    for row in rows {
        if let tokens = row.tokens { result.tokens?.add(tokens) }
        if let amount = row.cost {
            cost += amount; result.recordedCost.rowsWithCost += 1
            if amount == 0 { result.recordedCost.ambiguousZeroRows += 1 }
        } else { result.recordedCost.missingCostRows += 1 }
    }
    result.recordedCost.amount = rows.isEmpty || result.recordedCost.rowsWithCost > 0 ? NSDecimalNumber(decimal: cost).stringValue : nil
    result.estimate = ActivityPrices.estimate(rows)
    return result
}
