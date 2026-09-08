import SwiftUI
import TallyCore

struct OpenAICreditDetails: View {
    let account: Account
    @ObservedObject var runtime: Runtime
    @State var expanded = false
    @State var confirming: String?
    @State private var chosen: String?
    private var blocked: Bool {
        runtime.resetBusy.contains(account.id) || account.command.blockingOperationId != nil ||
        runtime.resetOperations[account.id].map { $0.state == .pending || $0.acknowledgementRequired } == true
    }
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
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    Text((groups.resetSummary.data?.availableCount.map { "\($0) reset credits" } ?? "Reset count unavailable") + (groups.resetSummary.stale ? " (stale)" : ""))
                }.padding(.vertical, 4)
            }.buttonStyle(.plain)
                .accessibilityLabel("Reset credit details for \(account.name)")
            if expanded {
                if let details = groups.resetDetails.data {
                    if details.credits.isEmpty { Text("No reset credits reported") }
                    ForEach(details.credits) { credit in
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(credit.title ?? "Reset credit").font(.subheadline.weight(.medium))
                                    Text(credit.expiry.kind == "none" ? "No expiry" : credit.expiry.at.map { "Expires \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Expiry unknown")
                                        .foregroundStyle(.secondary)
                                    if !credit.isUsable { Text("Unavailable").foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 0)
                                let operation = runtime.resetOperations[account.id]
                                if confirming != credit.id || blocked {
                                    Button(blocked && (operation == nil ? chosen : operation?.selectedCreditId ?? operation?.requestedCreditId) == credit.id && operation?.acknowledgementRequired != true ? "Redeeming…" : "Use credit") { confirming = credit.id }
                                        .controlSize(.small)
                                        .disabled(blocked || !credit.isUsable)
                                }
                            }
                            if confirming == credit.id && !blocked {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Use one credit on \(account.name)? This cannot be undone. OpenAI decides which windows reset.")
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack {
                                        Spacer()
                                        Button("Cancel") { confirming = nil }
                                        Button("Use credit") {
                                            confirming = nil; chosen = credit.id
                                            Task { await runtime.redeem(account, credit: credit) }
                                        }.disabled(!credit.isUsable)
                                    }.controlSize(.small)
                                }
                                .padding(10)
                                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            }
                            DisclosureGroup("Details") {
                                VStack(alignment: .leading, spacing: 8) {
                                    if let description = credit.description { Text(description) }
                                    DetailRows(rows: [("Type", credit.type ?? "Unknown"),
                                                      ("Status", credit.status ?? "Unknown"),
                                                      ("Available", credit.available.map { $0 ? "Yes" : "No" } ?? "Unknown"),
                                                      ("Granted", credit.grantedAt?.formatted(date: .abbreviated, time: .standard) ?? "Unavailable"),
                                                      ("Expiry", credit.expiry.kind == "none" ? "Does not expire" : credit.expiry.at?.formatted(date: .abbreviated, time: .standard) ?? "Expiry unknown")])
                                    Text("Credit ID").foregroundStyle(.secondary)
                                    Text(credit.id).textSelection(.enabled)
                                }.padding(.top, 6)
                            }.foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                } else { Text("Credit list unavailable") }
                Divider()
                DisclosureGroup("Collection details") {
                    VStack(alignment: .leading, spacing: 8) {
                        DetailRows(rows: [("Available", groups.resetSummary.data?.availableCount.map(String.init) ?? "Unavailable"),
                                          ("Provider-applicable", groups.resetSummary.data?.applicableAvailableCount.map(String.init) ?? "Not reported"),
                                          ("Count source", groups.resetSummary.data?.source ?? "Unavailable"),
                                          ("Mac timezone", TimeZone.current.identifier)]
                                   + groupDetailRows("Count", groups.resetSummary) + groupDetailRows("Credit list", groups.resetDetails))
                        Text("Dollar comparisons use a reference rate of USD 0.04 per purchased credit, not provider-reported cash.")
                    }.padding(.top, 6)
                }.foregroundStyle(.secondary)
            }
        }.font(.caption)
    }
}
