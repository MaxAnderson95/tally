import SwiftUI
import TallyCore

struct DetailRows: View {
    let rows: [(String, String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 12) {
                    Text(row.0).foregroundStyle(.secondary).frame(width: 108, alignment: .leading)
                    Text(row.1).frame(maxWidth: .infinity, alignment: .trailing).multilineTextAlignment(.trailing)
                }.fixedSize(horizontal: false, vertical: true)
            }
        }.font(.caption).textSelection(.enabled)
    }
}

func groupDetailRows<Value>(_ label: String, _ group: TallyCore.Group<Value>) -> [(String, String)] {
    var rows = [("\(label) observed", group.observedAt.map { "\($0.formatted()) (\($0.formatted(.relative(presentation: .named))))" } ?? "Never"),
                ("\(label) attempt", group.lastAttemptAt?.formatted() ?? "Never"),
                ("\(label) collection", group.refreshing ? "Refreshing" : group.stale ? "Stale" : group.data == nil ? "Not applicable / absent" : "Current"),
                ("\(label) next", group.nextAttemptAt?.formatted() ?? "Not scheduled")]
    if let error = group.error { rows.append(("\(label) error", error.message)) }
    return rows
}

struct AccountDetails: View {
    let account: Account
    var body: some View { DetailRows(rows: rows) }
    private var rows: [(String, String)] {
        let groups = account.groups
        var rows = [("Mac timezone", TimeZone.current.identifier)]
        rows += groupDetailRows("Plan", groups.plan)
        rows += groupDetailRows("Quotas", groups.quotas)
        rows += groupDetailRows(account.provider == "xai" ? "PAYG" : "Extra usage", groups.extraUsage)
        rows += groupDetailRows("Purchased credits", groups.balances)
        rows += groupDetailRows("Reset count", groups.resetSummary)
        rows += groupDetailRows("Reset details", groups.resetDetails)
        if account.provider == "openai" {
            rows += [("Available resets", groups.resetSummary.data?.availableCount.map(String.init) ?? "Unavailable"),
                     ("Provider-applicable", groups.resetSummary.data?.applicableAvailableCount.map(String.init) ?? "Not reported")]
        }
        if let used = groups.extraUsage.data?.used {
            rows.append((account.provider == "xai" ? "PAYG source" : "Extra usage source", "\(used.source.amount) \(used.source.unit); exponent \(used.source.exponent.map(String.init) ?? "unknown")"))
        }
        for window in account.overviewWindows {
            rows += [("\(window.label) scope", window.scopeNote ?? window.scope),
                     ("Observed used", window.usedPercent.map { "\($0.formatted())%" } ?? "?"),
                     ("Exact reset", window.resetAt?.formatted(date: .abbreviated, time: .standard) ?? (window.resetState == "not_started" ? "Not started" : "Unavailable"))]
            if let pacing = window.pacing {
                rows += [("Projected at reset", "\(pacing.projectedUsedPercent.formatted())%"),
                         ("Spare allowance", "\(pacing.sparePercent.formatted())%"),
                         ("Average-rate run-out", pacing.runOutAt?.formatted(date: .abbreviated, time: .standard) ?? pacing.runOutReason ?? "Unavailable")]
            } else { rows.append(("Pacing", window.pacingUnavailableReason ?? "Unavailable")) }
        }
        return rows
    }
}
