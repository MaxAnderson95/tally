import Foundation

public struct Redemption: Codable, Sendable {
    public enum State: String, Codable, Sendable { case pending, confirmed, nothing_to_reset, no_credit, failed, unknown }
    public struct ProviderResult: Codable, Sendable {
        public var code: String
        @Null public var windowsReset: Int? = nil
    }
    public var operationId: String
    public var accountId: String
    public var accountName: String
    @Null public var requestedCreditId: String? = nil
    @Null public var selectedCreditId: String? = nil
    public var createdAt: Date
    public var updatedAt: Date
    public var state: State = .pending
    @Null public var providerResult: ProviderResult? = nil
    @Null public var error: Fault? = nil
    public var acknowledgementRequired = false
    @Null public var acknowledgedAt: Date? = nil
    public var resultUrl: String
}

struct RedemptionRecord: Codable, Sendable {
    var result: Redemption
    var namespace: String
    var target: IdentityEvidence
    var maySend = false

    var blocking: Bool { result.state == .pending || (result.state == .unknown && result.acknowledgedAt == nil) }

    mutating func interrupt(at now: Date) {
        result.state = maySend ? .unknown : .failed
        result.acknowledgementRequired = maySend
        result.updatedAt = now
        result.providerResult = nil
        result.error = maySend
            ? Fault("provider_response_unknown", "A consume may have reached OpenAI. Acknowledge this uncertainty before requesting another reset; acknowledgement never retries.")
            : Fault("interrupted_before_send", "The operation stopped before a consume could be sent.")
    }
}

func selectCredit(_ details: ResetDetails, requested: String?, at now: Date) -> Credit? {
    details.credits.filter {
        !$0.id.isEmpty && $0.available == true && $0.status == "available" &&
        ($0.expiry.at.map { $0 > now } ?? true) && (requested == nil || requested == $0.id)
    }.sorted {
        func rank(_ credit: Credit) -> Int { credit.expiry.kind == "at" && credit.expiry.at != nil ? 0 : credit.expiry.kind == "none" ? 1 : 2 }
        if rank($0) != rank($1) { return rank($0) < rank($1) }
        if rank($0) == 0, $0.expiry.at != $1.expiry.at { return $0.expiry.at! < $1.expiry.at! }
        return $0.id < $1.id
    }.first
}

func operationUUID(_ text: String) throws -> String {
    guard text.count == 36, let id = UUID(uuidString: text) else { throw Fault("invalid_request", "operationId must be a UUID.") }
    return id.uuidString
}
