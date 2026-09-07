import Foundation

public struct Money: Codable, Sendable {
    public struct Source: Codable, Sendable {
        public var amount: String
        public var unit: String
        @Null public var exponent: Int? = nil
    }
    public var amount: String
    public var currency: String
    public var provenance = "provider"
    public var source: Source
}

public struct ExtraUsage: Codable, Sendable {
    @Null public var enabled: Bool? = nil
    @Null public var used: Money? = nil
    @Null public var limit: Money? = nil
    @Null public var remaining: Money? = nil
    @Null public var remainingPercent: Double? = nil
    @Null public var periodLabel: String? = nil
    public var presentation = "unavailable"

    mutating func derive() {
        remaining = nil; remainingPercent = nil; presentation = "unavailable"
        if enabled == false { presentation = "off"; return }
        guard enabled == true, let used, let amount = Decimal(string: used.amount) else { return }
        presentation = "used_only"
        guard let limit, limit.currency == used.currency,
              let cap = Decimal(string: limit.amount), cap > 0 else { return }
        let available = max(0, cap - amount)
        remaining = Money(amount: "\(available)", currency: used.currency,
                          source: Money.Source(amount: "\(available)", unit: used.currency))
        remainingPercent = min(100, max(0, NSDecimalNumber(decimal: available / cap * 100).doubleValue))
        presentation = "bounded"
    }
}
