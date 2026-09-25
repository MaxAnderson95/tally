import SwiftUI
import TallyCore

struct RecordedActivity: View {
    @ObservedObject var runtime: Runtime
    @State private var pointed: Int?
    @State private var openProviders: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let group = runtime.activity?.activity
            if let error = group?.error { Text(error.message).foregroundStyle(Palette.ember) }
            panel {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan usage").font(.system(size: 13, weight: .bold))
                    Text("Tokens your subscriptions covered, and what they would cost at pay-as-you-go API prices.")
                        .font(.system(size: 11)).foregroundStyle(Palette.dust).fixedSize(horizontal: false, vertical: true)
                }
                SlidingSegments(options: ActivityRange.allCases.map { ($0, $0.label) }, selection: $runtime.activityRange)
                    .accessibilityElement(children: .contain).accessibilityLabel("Activity range")
                if let data = group?.data {
                    HStack(spacing: 8) {
                        stat("Tokens", data.totals.rows == 0 ? "0" : data.totals.tokens.map { Self.compact($0.total) } ?? "Unknown")
                        stat("API equivalent", Self.apiValue(data.totals) ?? "$0")
                    }
                    if data.totals.estimate.status == "partial" || data.totals.missingUsageRows > 0 {
                        Text([data.totals.estimate.status == "partial" ? "Some models have no listed API price, so the equivalent is a floor." : nil,
                              data.totals.missingUsageRows > 0 ? "\(data.totals.missingUsageRows) records have no usage recorded." : nil].compactMap { $0 }.joined(separator: " "))
                            .font(.system(size: 10.5)).foregroundStyle(Palette.dust).fixedSize(horizontal: false, vertical: true)
                    }
                    providers(data)
                } else { Text(group == nil ? "Reading activity…" : "Activity unavailable").foregroundStyle(Palette.dust) }
            }
            if let data = group?.data { trend(data) }
            extraUsage
            if let group {
                Text((group.refreshing ? "Scanning OpenCode history. " : group.stale ? "Activity is out of date. " : group.observedAt.map { "Scanned \($0.formatted(.relative(presentation: .named))). " } ?? "")
                     + "Tokens come from this Mac's OpenCode history, grouped by provider rather than account." + (group.data.map { $0.pricing.basis == "models_dev_catalog" ? " API prices come from models.dev, as of \($0.pricing.observedOn)." : " API prices are Tally's built-in reference rates from \($0.pricing.observedOn)." } ?? ""))
                    .font(.system(size: 10.5)).foregroundStyle(Palette.dust).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
        }.font(.system(size: 12))
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(Palette.dust)
            Text(value).font(.readout(17, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText()).animation(.snappy, value: value)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10))
    }

    // Provider-reported money charged beyond a plan. Local token history cannot tell which requests were billed this way.
    @ViewBuilder private var extraUsage: some View {
        let billed = (runtime.snapshot?.accounts ?? []).filter { ($0.provider == "anthropic" || $0.provider == "xai") && $0.groups.extraUsage.data.map { $0.presentation != "unavailable" } == true }
        let total = billed.compactMap { $0.groups.extraUsage.data?.used }.filter { $0.currency == "USD" }.reduce(0) { $0 + (Double($1.amount) ?? 0) }
        panel {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Extra usage billed").font(.system(size: 13, weight: .bold))
                    Text("Real charges beyond your plans, this billing period, as reported by each provider.")
                        .font(.system(size: 11)).foregroundStyle(Palette.dust).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(Self.money(String(total))).font(.readout(17, weight: .bold))
                    .contentTransition(.numericText()).animation(.snappy, value: total)
            }
            if billed.isEmpty { Text("No account reports extra usage.").foregroundStyle(Palette.dust) }
            ForEach(billed) { account in
                let extra = account.groups.extraUsage.data!
                HStack(spacing: 8) {
                    ProviderLogo(provider: account.provider, color: account.identityColorIndex, size: 13)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(account.name).fontWeight(.semibold)
                        Text("\(ProviderArtwork.logos[account.provider]?.name ?? account.provider) \(account.provider == "xai" ? "PAYG" : "extra usage")\(account.groups.extraUsage.stale ? ", out of date" : "")")
                            .font(.system(size: 10.5)).foregroundStyle(Palette.dust)
                    }
                    Spacer()
                    if extra.presentation == "off" && (Double(extra.used?.amount ?? "0") ?? 0) == 0 {
                        Text("Off").foregroundStyle(Palette.dust)
                    } else {
                        Text(extra.used.map { "\($0.currency) \($0.amount)" } ?? "Unavailable").fontWeight(.semibold)
                    }
                }
            }
        }
    }

    private func trend(_ data: ActivityData) -> some View {
        let days = data.trend.days
        let maximum = max(1, days.compactMap { $0.totals.tokens?.total }.max() ?? 0)
        let focus = pointed.flatMap { days.indices.contains($0) ? days[$0] : nil }
        return VStack(alignment: .leading, spacing: 10) {
            Group {
                if let focus {
                    Text(Self.day(focus.date, weekday: true)).fontWeight(.semibold) + Text("  " + Self.tokens(focus.totals) + (Self.apiValue(focus.totals).map { ", API equivalent \($0)" } ?? "")).foregroundStyle(Palette.dust)
                } else {
                    Text("Daily tokens").fontWeight(.bold) + Text("  Last 30 days, selected range in ink").foregroundStyle(Palette.dust)
                }
            }.font(.system(size: 11.5)).lineLimit(1)
            GeometryReader { geometry in
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(days.enumerated()), id: \.element.date) { index, day in
                        Capsule().fill(index == pointed ? Palette.active : day.selected ? Palette.ink : Palette.spent)
                            .frame(height: max(3, (day.totals.tokens?.total ?? 0) / maximum * geometry.size.height))
                            .scaleEffect(x: index == pointed ? 1.35 : 1, anchor: .bottom)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .animation(.easeOut(duration: 0.45), value: data.range)
                .animation(.spring(duration: 0.25, bounce: 0.3), value: pointed)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let location) = phase, !days.isEmpty {
                        pointed = min(days.count - 1, max(0, Int(location.x / geometry.size.width * CGFloat(days.count))))
                    } else { pointed = nil }
                }
            }.frame(height: 72).accessibilityLabel("Daily recorded tokens for 30 days")
            HStack { Text(days.first.map { Self.day($0.date) } ?? ""); Spacer(); Text(days.last.map { Self.day($0.date) } ?? "") }
                .font(.system(size: 10.5)).foregroundStyle(Palette.dust)
        }
        .padding(14).background(Palette.panel, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line))
    }

    private func providers(_ data: ActivityData) -> some View {
        let total = data.totals.tokens?.total ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(data.providers.enumerated()), id: \.element.provider) { index, provider in
                if index > 0 { Divider().overlay(Palette.line) }
                let open = openProviders.contains(provider.provider)
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { if open { openProviders.remove(provider.provider) } else { openProviders.insert(provider.provider) } }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                ProviderLogo(provider: provider.provider, color: 0, size: 13)
                                Text(ProviderArtwork.logos[provider.provider]?.name ?? provider.label).fontWeight(.semibold)
                                Spacer()
                                Text(Self.tokens(provider.totals)).font(.readout(11.5))
                                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.dust)
                                    .rotationEffect(.degrees(open ? 180 : 0))
                            }
                            TallyMeter(percent: total > 0 ? (provider.totals.tokens?.total ?? 0) / total * 100 : 0, height: 8)
                            if let price = Self.apiValue(provider.totals) { Text("API equivalent \(price)").font(.system(size: 11)).foregroundStyle(Palette.dust) }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("\(provider.label) models")
                    if open {
                        VStack(spacing: 6) {
                            ForEach(provider.models, id: \.modelId) { model in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(model.modelId).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(Self.tokens(model.totals) + (Self.apiValue(model.totals).map { ", \($0)" } ?? "")).foregroundStyle(Palette.dust)
                                }
                            }
                        }.font(.system(size: 11)).padding(.top, 4)
                    }
                }.padding(.vertical, 10)
            }
        }
    }

    static func compact(_ value: Double) -> String { value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
    static func money(_ value: String) -> String {
        let amount = Double(value) ?? 0
        return amount.formatted(.currency(code: "USD").precision(.fractionLength(amount >= 100 ? 0 : 2)))
    }
    static func tokens(_ value: ActivityAggregate) -> String {
        value.rows == 0 ? "no activity" : value.tokens.map { compact($0.total) + " tokens" } ?? "usage missing"
    }
    // Partial bounds cover priced components only, so the lower bound is the only honest claim about all activity.
    static func apiValue(_ value: ActivityAggregate) -> String? {
        let estimate = value.estimate
        if estimate.status == "empty" { return nil }
        guard let lower = estimate.lower, let upper = estimate.upper else { return "Not priced" }
        if estimate.status == "partial" { return "at least \(money(lower))" }
        return lower == upper ? money(lower) : "\(money(lower)) to \(money(upper))"
    }
    static func day(_ date: String, weekday: Bool = false) -> String {
        let parser = DateFormatter(); parser.dateFormat = "yyyy-MM-dd"; parser.timeZone = TimeZone(identifier: "UTC")
        guard let value = parser.date(from: date) else { return date }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day(); style.timeZone = TimeZone(identifier: "UTC")!
        if weekday { style = style.weekday(.abbreviated) }
        return value.formatted(style)
    }
}

/// Options share one capsule that slides to the selection.
struct SlidingSegments<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    @Namespace private var pill
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { withAnimation(.spring(duration: 0.38, bounce: 0.28)) { selection = option.value } } label: {
                    Text(option.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(selected ? Palette.ink : Palette.dust)
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .background {
                            if selected {
                                Capsule().fill(Palette.raised).shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }.buttonStyle(PressableStyle()).accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2).background(Palette.wash, in: Capsule()).overlay(Capsule().strokeBorder(Palette.line))
    }
}
