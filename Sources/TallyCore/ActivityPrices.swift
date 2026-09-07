import Foundation
import CryptoKit

// One immutable resource contains the rates and their evidence. No caller selects a rate or tier.
struct ActivityPrices: Decodable, Sendable {
    var revision: String
    var observedOn: String
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
    static let bundled = digest == "1753c13f0c8e53de55320e6318319d7601010468610772197002f0dae2ad70c5" ? try? JSONDecoder().decode(Self.self, from: bytes) : nil

    struct Bounds: Decodable, Sendable {
        let lower: Decimal
        let upper: Decimal
        init(from decoder: any Decoder) throws {
            var values = try decoder.unkeyedContainer()
            lower = try values.decode(Decimal.self); upper = try values.decode(Decimal.self)
            guard values.isAtEnd, !lower.isNaN, !upper.isNaN, lower >= 0, upper >= lower else {
                throw DecodingError.dataCorruptedError(in: values, debugDescription: "Invalid reviewed rate bounds")
            }
        }
    }
    struct Rates: Decodable, Sendable {
        var input: Bounds?
        var output: Bounds?
        var cacheRead: Bounds?
        var cacheWrite: Bounds?
    }
    struct Model: Decodable, Sendable {
        var provider: String
        var model: String
        var aliases: [String]?
        var rates: Rates
        var tier: Tier?
    }
    struct Tier: Decodable, Sendable {
        enum Operator: String, Decodable { case gt, gte }
        var threshold: Double
        var `operator`: Operator
        var rates: Rates
        func applies(_ prompt: Double) -> Bool { `operator` == .gt ? prompt > threshold : prompt >= threshold }
    }

    static func estimate(_ rows: [ActivityRow]) -> Estimate {
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
            guard let book = bundled else { unpriced("Reviewed pricing bundle unavailable"); continue }
            guard let model = book.models.first(where: { $0.provider == row.provider && ($0.model == row.model || $0.aliases?.contains(row.model) == true) }) else {
                unpriced("No reviewed exact model or explicit alias")
                continue
            }
            let prompt = tokens.input + tokens.cacheRead + tokens.cacheWrite
            guard prompt.isFinite else { unpriced("Input tier cannot be reconstructed"); continue }
            let rates = model.tier.map { $0.applies(prompt) ? $0.rates : model.rates } ?? model.rates
            let components: [(WritableKeyPath<Tokens, Double>, Bounds?)] = [
                (\.input, rates.input), (\.output, rates.output), (\.reasoning, rates.output),
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
