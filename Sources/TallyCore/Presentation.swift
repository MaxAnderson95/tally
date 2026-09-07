import Foundation

extension Account {
    public var overviewWindows: [QuotaWindow] {
        (groups.quotas.data?.windows.filter(\.displayInOverview) ?? []).sorted {
            let left = $0.durationSeconds ?? .infinity
            let right = $1.durationSeconds ?? .infinity
            return left == right ? $0.id < $1.id : left < right
        }
    }

    public var latestObservation: Date? {
        [groups.plan.observedAt, groups.quotas.observedAt, groups.extraUsage.observedAt,
         groups.balances.observedAt, groups.resetSummary.observedAt, groups.resetDetails.observedAt].compactMap { $0 }.max()
    }

    mutating func derivePresentation() {
        pin = Pin()
        guard groups.quotas.observedAt != nil, let quotas = groups.quotas.data else { return }
        let eligible = quotas.windows.filter {
            $0.scope == "account" && $0.cadence != "monthly" && ($0.durationSeconds ?? 0) > 0
        }
        let durations = Dictionary(grouping: eligible, by: { $0.durationSeconds! })
        pin.lines = durations.keys.sorted().prefix(2).compactMap { duration in
            let candidates = durations[duration]!
            // An unknown peer prevents claiming a measured worst case for this duration.
            let unknown = candidates.filter { $0.remainingPercent == nil }.sorted { $0.id < $1.id }
            let selected = unknown.first ?? candidates.sorted {
                $0.remainingPercent == $1.remainingPercent ? $0.id < $1.id : $0.remainingPercent! < $1.remainingPercent!
            }.first!
            return PinLine(windowId: selected.id, label: selected.label, remainingPercent: selected.remainingPercent,
                           stale: candidates.contains(where: \.stale))
        }
        pin.warning = groups.quotas.stale || pin.lines.contains(where: \.stale)
    }
}
