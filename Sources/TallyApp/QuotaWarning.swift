import SwiftUI
import TallyCore

struct QuotaWarning: View {
    let account: Account
    var inventoryError: Fault?
    @State private var showingExplanation = false

    var body: some View {
        if let message = Self.message(for: account, inventoryError: inventoryError) {
            Button { showingExplanation.toggle() } label: {
                Image(systemName: "exclamationmark.triangle")
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(message + "\nClick for details.")
            .accessibilityLabel("Quota warning for \(account.name). \(message)")
            .popover(isPresented: $showingExplanation) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Quota warning").font(.headline)
                    Text(message).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(14).frame(width: 300, alignment: .leading)
            }
        }
    }

    static func message(for account: Account, inventoryError: Fault? = nil, now: Date = Date()) -> String? {
        let quotas = account.groups.quotas
        let staleWindows = quotas.data?.windows.filter(\.stale) ?? []
        guard quotas.stale || quotas.error != nil || !staleWindows.isEmpty else { return nil }
        var reasons: [String] = []
        if let error = quotas.error ?? inventoryError { reasons.append(error.message) }
        if let observed = quotas.observedAt {
            reasons.append("Last successful quota reading: \(observed.formatted(date: .abbreviated, time: .standard)).")
            if quotas.stale { reasons.append("Showing saved percentages; current usage may differ.") }
        } else {
            reasons.append("No successful quota reading yet.")
        }
        for window in staleWindows {
            if window.resetState == "passed" {
                reasons.append("\(window.label): reset time passed; awaiting an updated reading.")
            } else if !quotas.stale {
                reasons.append("\(window.label): the reading is stale.")
            }
        }
        if quotas.refreshing {
            reasons.append("Retrying now…")
        } else if let next = quotas.nextAttemptAt ?? quotas.error?.retryAt {
            reasons.append(next > now
                ? "Next automatic attempt: \(next.formatted(date: .omitted, time: .standard))."
                : "Waiting for the scheduled retry.")
        }
        reasons.append("Click Refresh to retry now.")
        return reasons.joined(separator: "\n\n")
    }
}
