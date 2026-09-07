import SwiftUI
import TallyCore

struct OpenAICreditDetails: View {
    let account: Account
    var body: some View {
        let groups = account.groups
        VStack(alignment: .leading, spacing: 8) {
            Text("Purchased credits").font(.subheadline)
            if let balances = groups.balances.data {
                ForEach(Array(balances.items.enumerated()), id: \.offset) { _, balance in
                    Text(balance.unlimited == true ? "Unlimited \(balance.unit)" : "\(balance.quantity ?? "Unknown") \(balance.unit)")
                    if let reference = balance.referenceValue {
                        Text("\(reference.currency) \(reference.amount), reference-derived").font(.caption)
                    }
                }
            } else { Text("Unavailable") }
            if groups.balances.stale { Text("Purchased credits stale").font(.caption) }
            DisclosureGroup((groups.resetSummary.data?.availableCount.map { "\($0) reset credits" } ?? "Reset count unavailable") + (groups.resetSummary.stale ? " (stale)" : "")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reset credits for \(account.name)").font(.headline)
                    Text("Redeeming consumes one credit; the provider decides which windows reset.")
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow { Text("Available"); Text(groups.resetSummary.data?.availableCount.map(String.init) ?? "Unavailable") }
                        GridRow { Text("Provider-applicable"); Text(groups.resetSummary.data?.applicableAvailableCount.map(String.init) ?? "Not reported") }
                        GridRow { Text("Count source"); Text(groups.resetSummary.data?.source ?? "Unavailable") }
                        GridRow { Text("Timezone"); Text(TimeZone.current.identifier) }
                        CreditGroupRows(label: "Count", group: groups.resetSummary)
                        CreditGroupRows(label: "Credit list", group: groups.resetDetails)
                        CreditGroupRows(label: "Purchased credits", group: groups.balances)
                    }
                    Text("Dollar comparisons use a reference rate of USD 0.04 per purchased credit, not provider-reported cash.")
                    if let details = groups.resetDetails.data {
                        if details.credits.isEmpty { Text("No reset credits reported") }
                        ForEach(details.credits) { credit in
                            Text(credit.title ?? "Reset credit").font(.headline)
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                                GridRow { Text("Credit ID"); Text(credit.id) }
                                GridRow { Text("Type"); Text(credit.type ?? "Unknown") }
                                GridRow { Text("Status"); Text(credit.status ?? "Unknown") }
                                GridRow { Text("Available"); Text(credit.available.map { $0 ? "Yes" : "No" } ?? "Unknown") }
                                GridRow { Text("Granted"); Text(credit.grantedAt?.formatted() ?? "Unavailable") }
                                GridRow { Text("Expiry"); Text(credit.expiry.kind == "none" ? "Does not expire" : credit.expiry.at?.formatted() ?? "Expiry unknown") }
                                if let description = credit.description { GridRow { Text("Description"); Text(description) } }
                            }
                        }
                    } else { Text("Credit list unavailable") }
                }.font(.caption).padding(.top, 8)
            }
        }.font(.subheadline)
    }
}

private struct CreditGroupRows<Value: Codable & Sendable>: View {
    let label: String
    let group: TallyCore.Group<Value>
    var body: some View {
        GridRow { Text("\(label) observed"); Text(group.observedAt?.formatted() ?? "Never") }
        GridRow { Text("\(label) attempt"); Text(group.lastAttemptAt?.formatted() ?? "Never") }
        GridRow { Text("\(label) collection"); Text(group.refreshing ? "Refreshing" : group.stale ? "Stale" : "Current") }
        GridRow { Text("\(label) next"); Text(group.nextAttemptAt?.formatted() ?? "Not scheduled") }
        if let error = group.error { GridRow { Text("\(label) error"); Text(error.message) } }
    }
}
