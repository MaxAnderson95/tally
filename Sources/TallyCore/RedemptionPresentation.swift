import Foundation

public extension Credit {
    var isUsable: Bool {
        available == true && (expiry.kind != "at" || expiry.at.map { $0 > Date() } == true)
    }
}

public extension Redemption {
    func displayMessage(for account: Account) -> String {
        switch state {
        case .pending: return "Redeeming…"
        case .confirmed:
            if account.groups.quotas.stale || account.groups.quotas.error != nil || account.groups.resetDetails.error != nil {
                return "Reset confirmed. Current usage readings are stale or unavailable."
            }
            return providerResult?.code == "already_redeemed" ? "Credit already redeemed; no additional reset claimed." : "Reset confirmed."
        case .nothing_to_reset: return "Provider reports nothing to reset."
        case .no_credit: return "No available reset credit."
        case .failed: return error?.message ?? "Reset failed before consumption."
        case .unknown:
            return acknowledgementRequired
                ? "Outcome unknown. A credit may have been consumed. Acknowledge to allow another deliberate reset; the outcome stays unknown and acknowledgement never retries consumption."
                : "Outcome unknown; acknowledged. No consumption was retried."
        }
    }
}
