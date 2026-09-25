import Foundation
import CryptoKit

// A price book: the reviewed bundle until models.dev has been read, then the latest models.dev catalog. No caller selects a rate or tier.
struct ActivityPrices: Codable, Sendable {
    var revision: String
    var observedOn: String
    var basis = "standard_global_api_equivalent"
    var digest = ""
    var models: [Model]
    private static let resourceURL: URL? = {
        // SwiftPM's generated accessor searches beside the executable, not an app's Resources directory.
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.url(forResource: "pricing", withExtension: "json", subdirectory: "Tally_TallyCore.bundle")
        }
        return Bundle.module.url(forResource: "pricing", withExtension: "json")
    }()
    static let bytes = resourceURL.flatMap { try? Data(contentsOf: $0) } ?? Data()
    static let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    static let bundled: ActivityPrices? = {
        guard digest == "1753c13f0c8e53de55320e6318319d7601010468610772197002f0dae2ad70c5", var book = try? JSONDecoder().decode(Self.self, from: bytes) else { return nil }
        book.digest = digest
        return book
    }()

    private enum CodingKeys: String, CodingKey { case revision, observedOn, basis, digest, models }
    init(revision: String, observedOn: String, basis: String, digest: String, models: [Model]) {
        self.revision = revision; self.observedOn = observedOn; self.basis = basis; self.digest = digest; self.models = models
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        revision = try values.decode(String.self, forKey: .revision)
        observedOn = try values.decode(String.self, forKey: .observedOn)
        basis = try values.decodeIfPresent(String.self, forKey: .basis) ?? "standard_global_api_equivalent"
        digest = try values.decodeIfPresent(String.self, forKey: .digest) ?? ""
        models = try values.decode([Model].self, forKey: .models)
    }

    /// Builds a book from models.dev's `api.json`. models.dev lists one rate per component, so every rate is scalar,
    /// and its long-context tier applies once a request's prompt exceeds the tier size.
    static func modelsDev(_ data: Data, fetchedAt: Date) throws -> ActivityPrices {
        struct Cost: Decodable {
            struct Tier: Decodable {
                struct Size: Decodable { var type: String; var size: Double }
                var input: Decimal?; var output: Decimal?; var reasoning: Decimal?
                var cache_read: Decimal?; var cache_write: Decimal?; var tier: Size?
            }
            var input: Decimal?; var output: Decimal?; var reasoning: Decimal?
            var cache_read: Decimal?; var cache_write: Decimal?; var tiers: [Tier]?
        }
        struct Entry: Decodable { var cost: Cost? }
        struct Provider: Decodable { var models: [String: Entry] }
        func bounds(_ value: Decimal?) -> Bounds? { value.flatMap { $0.isNaN || $0 < 0 ? nil : Bounds(lower: $0, upper: $0) } }
        let catalog = try JSONDecoder().decode([String: Provider].self, from: data)
        var models: [Model] = []
        for provider in providerOrder {
            for (id, entry) in catalog[provider]?.models ?? [:] {
                guard let cost = entry.cost else { continue }
                let rates = Rates(input: bounds(cost.input), output: bounds(cost.output), reasoning: bounds(cost.reasoning),
                                  cacheRead: bounds(cost.cache_read), cacheWrite: bounds(cost.cache_write))
                let long = cost.tiers?.first { $0.tier?.type == "context" }
                let tier = long.flatMap { tier in tier.tier.map {
                    Tier(threshold: $0.size, operator: .gt, rates: Rates(input: bounds(tier.input), output: bounds(tier.output), reasoning: bounds(tier.reasoning),
                                                                           cacheRead: bounds(tier.cache_read), cacheWrite: bounds(tier.cache_write)))
                } }
                models.append(Model(provider: provider, model: id, rates: rates, tier: tier))
            }
        }
        guard !models.isEmpty else { throw Fault("pricing_catalog_empty", "models.dev listed no priced models for supported providers.") }
        models.sort { ($0.provider, $0.model) < ($1.provider, $1.model) }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let digest = SHA256.hash(data: try encoder.encode(models)).map { String(format: "%02x", $0) }.joined()
        let day = Calendar.current
        let parts = day.dateComponents([.year, .month, .day], from: fetchedAt)
        return ActivityPrices(revision: "models.dev-" + digest.prefix(12), observedOn: String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!),
                              basis: "models_dev_catalog", digest: digest, models: models)
    }

    struct Bounds: Codable, Sendable {
        let lower: Decimal
        let upper: Decimal
        init(lower: Decimal, upper: Decimal) { self.lower = lower; self.upper = upper }
        func encode(to encoder: any Encoder) throws {
            var values = encoder.unkeyedContainer()
            try values.encode(lower); try values.encode(upper)
        }
        init(from decoder: any Decoder) throws {
            var values = try decoder.unkeyedContainer()
            lower = try values.decode(Decimal.self); upper = try values.decode(Decimal.self)
            guard values.isAtEnd, !lower.isNaN, !upper.isNaN, lower >= 0, upper >= lower else {
                throw DecodingError.dataCorruptedError(in: values, debugDescription: "Invalid reviewed rate bounds")
            }
        }
    }
    struct Rates: Codable, Sendable {
        var input: Bounds?
        var output: Bounds?
        // Reasoning uses the output rate unless the catalog lists its own.
        var reasoning: Bounds?
        var cacheRead: Bounds?
        var cacheWrite: Bounds?
    }
    struct Model: Codable, Sendable {
        var provider: String
        var model: String
        var aliases: [String]?
        var rates: Rates
        var tier: Tier?
    }
    struct Tier: Codable, Sendable {
        enum Operator: String, Codable { case gt, gte }
        var threshold: Double
        var `operator`: Operator
        var rates: Rates
        func applies(_ prompt: Double) -> Bool { `operator` == .gt ? prompt > threshold : prompt >= threshold }
    }

    static func estimate(_ rows: [ActivityRow], prices: ActivityPrices? = bundled) -> Estimate {
        var result = Estimate(), lower = Decimal.zero, upper = Decimal.zero
        func exclude(_ row: ActivityRow, _ reason: String, _ tokens: Tokens?) {
            if let index = result.exclusions.firstIndex(where: { $0.provider == row.provider && $0.modelId == row.model && $0.reason == reason }) {
                result.exclusions[index].rows += 1
                if let tokens { result.exclusions[index].tokens?.add(tokens) }
            } else { result.exclusions.append(PricingExclusion(provider: row.provider, modelId: row.model, reason: reason, rows: 1, tokens: tokens)) }
        }
        for row in rows {
            guard let tokens = row.tokens else {
                result.coverage.missingUsageRows += 1
                exclude(row, "Usage missing", nil)
                continue
            }
            func unpriced(_ reason: String) {
                result.coverage.unpricedRows += 1; result.coverage.unpricedComponents.add(tokens)
                exclude(row, reason, tokens)
            }
            let quantities = [tokens.input, tokens.output, tokens.reasoning, tokens.cacheRead, tokens.cacheWrite]
            guard quantities.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                unpriced("Invalid token reconstruction: negative or nonfinite retained component; signed records preserved")
                continue
            }
            guard let book = prices else { unpriced("API prices are not loaded yet"); continue }
            guard let model = book.models.first(where: { $0.provider == row.provider && ($0.model == row.model || $0.aliases?.contains(row.model) == true) }) else {
                unpriced("No listed price for this exact model")
                continue
            }
            let prompt = tokens.input + tokens.cacheRead + tokens.cacheWrite
            guard prompt.isFinite else { unpriced("Input tier cannot be reconstructed"); continue }
            let rates = model.tier.map { $0.applies(prompt) ? $0.rates : model.rates } ?? model.rates
            let components: [(WritableKeyPath<Tokens, Double>, Bounds?)] = [
                (\.input, rates.input), (\.output, rates.output), (\.reasoning, rates.reasoning ?? rates.output),
                (\.cacheRead, rates.cacheRead), (\.cacheWrite, rates.cacheWrite)
            ]
            var priced = Tokens(), excluded = Tokens(), rowLower = Decimal.zero, rowUpper = Decimal.zero
            var hasPrice = false, hasExclusion = false, invalid = false
            for (key, rate) in components {
                let quantity = tokens[keyPath: key]
                if let rate, let count = Decimal(string: String(quantity), locale: Locale(identifier: "en_US_POSIX")), !count.isNaN {
                    priced[keyPath: key] = quantity
                    rowLower += count * rate.lower / 1_000_000; rowUpper += count * rate.upper / 1_000_000
                    if quantity > 0 { hasPrice = true }
                    if rowLower.isNaN || rowUpper.isNaN { invalid = true }
                } else {
                    excluded[keyPath: key] = quantity
                    if quantity > 0 { hasExclusion = true }
                }
            }
            guard !invalid else { unpriced("Reference amount exceeds supported decimal precision"); continue }
            // Verified all-zero usage is scalar zero; zeros alone do not price an unknown positive component.
            hasPrice = hasPrice || quantities.allSatisfy { $0 == 0 }
            guard hasPrice else { unpriced("No reviewed rate for positive recorded components"); continue }
            if hasExclusion {
                result.coverage.partiallyPricedRows += 1
                excluded.add(Tokens())
                exclude(row, "Positive token component has no reviewed rate", excluded)
            } else if rowLower != rowUpper { result.coverage.boundedRows += 1 }
            else { result.coverage.fullyPricedRows += 1 }
            result.coverage.pricedComponents.add(priced); result.coverage.unpricedComponents.add(excluded)
            lower += rowLower; upper += rowUpper
        }
        result.exclusions.sort {
            if $0.provider != $1.provider { return providerOrder.firstIndex(of: $0.provider)! < providerOrder.firstIndex(of: $1.provider)! }
            if $0.modelId != $1.modelId { return $0.modelId < $1.modelId }
            return $0.reason < $1.reason
        }
        let pricedRows = result.coverage.fullyPricedRows + result.coverage.boundedRows + result.coverage.partiallyPricedRows
        if !rows.isEmpty {
            result.status = pricedRows == 0 ? "unpriced" : !result.exclusions.isEmpty ? "partial" : lower == upper ? "scalar" : "range"
            result.lower = pricedRows == 0 ? nil : NSDecimalNumber(decimal: lower).stringValue
            result.upper = pricedRows == 0 ? nil : NSDecimalNumber(decimal: upper).stringValue
        }
        return result
    }
}

extension Estimate {
    public var label: String {
        if status == "empty" { return "API-equivalent estimate: No recorded activity" }
        guard let lower, let upper else { return "API-equivalent estimate: Unpriced" }
        let amount = lower == upper ? "$\(lower)" : "$\(lower) to $\(upper)"
        return "API-equivalent \(status == "partial" ? "partial subtotal" : "estimate"): \(amount) USD"
    }
    public var qualification: String {
        switch status {
        case "partial": "Incomplete: bounds cover priced components only; the upper value does not bound all activity."
        case "range": "Bounded reference: Anthropic writes use 5m/1h alternatives; Go DeepSeek uses off-peak/peak alternatives."
        case "unpriced": "No verified amount for these records; recorded cost is separate."
        default: "Dated standard/global reference-token value, not a bill, subscription charge, quota debit or savings."
        }
    }
}
