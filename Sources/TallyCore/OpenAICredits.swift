import Foundation

public struct Balances: Codable, Sendable { public var items: [Balance] }
public struct Balance: Codable, Sendable {
    public var unit: String
    @Null public var quantity: String? = nil
    @Null public var money: Money? = nil
    @Null public var referenceValue: Money? = nil
    @Null public var unlimited: Bool? = nil
}
public struct ResetSummary: Codable, Sendable {
    @Null public var availableCount: Int? = nil
    @Null public var applicableAvailableCount: Int? = nil
    public var source: String
}
public struct Credit: Codable, Sendable, Identifiable {
    public struct Expiry: Codable, Sendable {
        public var kind: String
        @Null public var at: Date? = nil
    }
    public var id: String
    @Null public var type: String? = nil
    @Null public var status: String? = nil
    @Null public var available: Bool? = nil
    @Null public var title: String? = nil
    @Null public var description: String? = nil
    @Null public var grantedAt: Date? = nil
    public var expiry: Expiry
}
public struct ResetDetails: Codable, Sendable {
    public var credits: [Credit]
    // Counts belong to this list observation, independently of the embedded usage summary.
    public var summary: ResetSummary
}

extension AccountGroups {
    mutating func selectResetSummary() {
        let details = resetDetails
        guard let data = details.data, let observed = details.observedAt,
              !details.stale || resetSummary.observedAt.map({ $0 <= observed }) ?? true else { return }
        resetSummary.data = data.summary
        resetSummary.observedAt = details.observedAt
        resetSummary.lastAttemptAt = details.lastAttemptAt
        resetSummary.stale = details.stale
        resetSummary.refreshing = details.refreshing
        resetSummary.nextAttemptAt = details.nextAttemptAt
        resetSummary.error = details.error
    }
}
