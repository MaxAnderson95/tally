import SwiftUI
import TallyCore

struct OpenAICreditDetails: View {
    let account: Account
    @State private var expanded = false
    var body: some View {
        let groups = account.groups
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Purchased credits")
                Spacer()
                Text(groups.balances.data?.items.map { balance in
                    if balance.unlimited == true { return "Unlimited \(balance.unit)" }
                    let reference = balance.referenceValue.map { " (\($0.currency) \($0.amount))" } ?? ""
                    return "\(balance.quantity ?? "Unknown") \(balance.unit)\(reference)"
                }.joined(separator: ", ") ?? "Unavailable").multilineTextAlignment(.trailing)
            }
            if groups.balances.stale { Text("Purchased credits stale").font(.caption) }
            Button { expanded.toggle() } label: {
                Text((groups.resetSummary.data?.availableCount.map { "\($0) reset credits" } ?? "Reset count unavailable") + (groups.resetSummary.stale ? " (stale)" : ""))
                    .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(Capsule().stroke(.secondary.opacity(0.2)))
            }.buttonStyle(.plain)
            if expanded {
                Text("Reset credits for \(account.name)").font(.headline)
                Text("Redeeming consumes one credit; the provider decides which windows reset.")
                DetailRows(rows: [("Available", groups.resetSummary.data?.availableCount.map(String.init) ?? "Unavailable"),
                                  ("Provider-applicable", groups.resetSummary.data?.applicableAvailableCount.map(String.init) ?? "Not reported"),
                                  ("Count source", groups.resetSummary.data?.source ?? "Unavailable"),
                                  ("Mac timezone", TimeZone.current.identifier)]
                           + groupDetailRows("Count", groups.resetSummary) + groupDetailRows("Credit list", groups.resetDetails))
                Text("Dollar comparisons use a reference rate of USD 0.04 per purchased credit, not provider-reported cash.")
                if let details = groups.resetDetails.data {
                    if details.credits.isEmpty { Text("No reset credits reported") }
                    ForEach(details.credits) { credit in
                        Text(credit.title ?? "Reset credit").font(.headline)
                        DetailRows(rows: [("Credit ID", credit.id), ("Type", credit.type ?? "Unknown"),
                                          ("Status", credit.status ?? "Unknown"), ("Available", credit.available.map { $0 ? "Yes" : "No" } ?? "Unknown"),
                                          ("Granted", credit.grantedAt?.formatted(date: .abbreviated, time: .standard) ?? "Unavailable"),
                                          ("Expiry", credit.expiry.kind == "none" ? "Does not expire" : credit.expiry.at?.formatted(date: .abbreviated, time: .standard) ?? "Expiry unknown"),
                                          ("Description", credit.description ?? "Unavailable")])
                    }
                } else { Text("Credit list unavailable") }
            }
        }.font(.caption)
    }
}
