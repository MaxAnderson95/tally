import SwiftUI
import TallyCore

struct RecordedActivity: View {
    @ObservedObject var runtime: Runtime
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recorded OpenCode activity").font(.headline)
            HStack(spacing: 4) {
                ForEach(ActivityRange.allCases, id: \.self) { range in
                    Button { runtime.activityRange = range } label: {
                        Text(range.label).frame(maxWidth: .infinity).padding(.vertical, 6)
                            .background(Color.primary.opacity(runtime.activityRange == range ? 0.1 : 0))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(runtime.activityRange == range ? 1 : 0.15)))
                    }.buttonStyle(.plain).accessibilityAddTraits(runtime.activityRange == range ? .isSelected : [])
                }
            }.accessibilityLabel("Activity range")
            if let group = runtime.activity?.activity {
                Text(group.refreshing ? "Scanning…" : group.stale ? "Stale / unavailable" : "Current scan")
                if let observed = group.observedAt { Text("Scanned \(observed.formatted(.relative(presentation: .named)))") }
                if let error = group.error { Text(error.message) }
                if let data = group.data {
                    Text("\(data.range.label) · \(data.timezone)")
                    Text("Partial history · Provider/local-database attribution, not Accounts")
                    Text("Reference-token value · \(data.pricing.revision) · observed \(data.pricing.observedOn)")
                    Text("Standard/global comparison, not subscription charges, historical bills, quota debit or savings.")
                    ActivityTotals(value: data.totals)
                    Text("30-calendar-day token context; selected days are solid.")
                    let maximum = max(1, data.trend.days.compactMap { $0.totals.tokens?.total }.max() ?? 0)
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(data.trend.days, id: \.date) { day in
                            Rectangle().fill(Color.primary.opacity(day.selected ? 1 : 0.15))
                                .frame(height: max(2, (day.totals.tokens?.total ?? 0) / maximum * 80))
                                .help("\(day.date): \(day.totals.tokenLabel); \(day.totals.estimate.label); \(day.totals.missingUsageRows) usage missing")
                        }
                    }.frame(height: 80).accessibilityLabel("30-day recorded token trend")
                    HStack { Text(data.trend.days.first?.date ?? ""); Spacer(); Text(data.trend.days.last?.date ?? "") }
                    DisclosureGroup("Daily values") {
                        ForEach(data.trend.days, id: \.date) { day in
                            DisclosureGroup(day.date + (day.selected ? " (selected)" : "")) { ActivityTotals(value: day.totals) }
                        }
                    }
                    ForEach(data.providers, id: \.provider) { provider in
                        DisclosureGroup(provider.label) {
                            ActivityTotals(value: provider.totals)
                            ForEach(provider.models, id: \.modelId) { model in
                                DisclosureGroup(model.modelId) { ActivityTotals(value: model.totals) }
                            }
                        }
                    }
                    DisclosureGroup("Source, pricing, and freshness") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(data.source.qualifications, id: \.self) { Text($0) }
                            LabeledContent("Range start", value: exact(data.startAt, data.timezone))
                            LabeledContent("Exclusive end", value: exact(data.endAt, data.timezone))
                            LabeledContent("First retained", value: exact(data.source.firstRetainedAt, data.timezone))
                            LabeledContent("Last retained", value: exact(data.source.lastRetainedAt, data.timezone))
                            LabeledContent("Populated retained days", value: "\(data.source.populatedDays); not continuous coverage")
                            LabeledContent("Last attempt", value: exact(group.lastAttemptAt, data.timezone))
                            LabeledContent("Next scan", value: exact(group.nextAttemptAt, data.timezone))
                            LabeledContent("Pricing revision", value: "\(data.pricing.revision) (\(data.pricing.observedOn))")
                            LabeledContent("Pricing SHA-256", value: data.pricing.digest)
                        }
                    }
                } else { Text("Activity unavailable") }
            } else { Text("Activity unavailable") }
        }.font(.caption)
    }
    private func exact(_ value: Date?, _ timezone: String) -> String {
        guard let value else { return "Unavailable" }
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: timezone)
        formatter.dateStyle = .medium; formatter.timeStyle = .medium
        return formatter.string(from: value)
    }
}

private struct ActivityTotals: View {
    let value: ActivityAggregate
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value.tokenLabel).font(.headline)
            if value.missingUsageRows > 0 { Text("Usage missing for \(value.missingUsageRows) of \(value.rows) records; subtotal is incomplete.") }
            Text(value.costLabel)
            Text(value.estimate.label)
            Text(value.estimate.qualification)
            if !value.estimate.exclusions.isEmpty {
                ForEach(value.estimate.exclusions.indices, id: \.self) { index in
                    let exclusion = value.estimate.exclusions[index]
                    Text("\(exclusion.provider)/\(exclusion.modelId): \(exclusion.reason) (\(exclusion.rows) records; \(exclusion.tokens.map { $0.total.formatted() + " recorded tokens" } ?? "token quantity unknown"))")
                }
            }
            DisclosureGroup("Token and cost coverage") {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Retained records", value: "\(value.rows)")
                    if let tokens = value.tokens {
                        LabeledContent("Noncached input", value: tokens.input.formatted())
                        LabeledContent("Visible output", value: tokens.output.formatted())
                        LabeledContent("Reasoning", value: tokens.reasoning.formatted())
                        LabeledContent("Cache read", value: tokens.cacheRead.formatted())
                        LabeledContent("Cache write", value: tokens.cacheWrite.formatted())
                    }
                    LabeledContent("Rows with cost", value: "\(value.recordedCost.rowsWithCost)")
                    LabeledContent("Cost missing", value: "\(value.recordedCost.missingCostRows)")
                    LabeledContent("Ambiguous zero costs", value: "\(value.recordedCost.ambiguousZeroRows)")
                    LabeledContent("Unpriced rows", value: "\(value.estimate.coverage.unpricedRows)")
                    LabeledContent("Fully priced rows", value: "\(value.estimate.coverage.fullyPricedRows)")
                    LabeledContent("Bounded rows", value: "\(value.estimate.coverage.boundedRows)")
                    LabeledContent("Partially priced rows", value: "\(value.estimate.coverage.partiallyPricedRows)")
                    LabeledContent("Missing usage rows", value: "\(value.estimate.coverage.missingUsageRows)")
                    Text("Exclusion counts can overlap; row coverage categories are disjoint.")
                    ComponentCoverage(label: "Priced components", tokens: value.estimate.coverage.pricedComponents)
                    ComponentCoverage(label: "Unpriced known components", tokens: value.estimate.coverage.unpricedComponents)
                }
            }
        }
    }
}

private struct ComponentCoverage: View {
    let label: String
    let tokens: Tokens
    var body: some View {
        DisclosureGroup(label) {
            LabeledContent("Noncached input", value: tokens.input.formatted())
            LabeledContent("Visible output", value: tokens.output.formatted())
            LabeledContent("Reasoning", value: tokens.reasoning.formatted())
            LabeledContent("Cache read", value: tokens.cacheRead.formatted())
            LabeledContent("Cache write", value: tokens.cacheWrite.formatted())
            LabeledContent("Total", value: tokens.total.formatted())
        }
    }
}
