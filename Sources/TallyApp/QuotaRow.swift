import SwiftUI
import TallyCore

struct QuotaRow: View {
    let window: QuotaWindow
    var now = Date()

    var limitDate: Date? {
        guard !window.stale, let used = window.usedPercent, used >= 5 else { return nil }
        return window.pacing?.runOutAt
    }

    var body: some View {
        let limit = limitDate
        let running = limit != nil || window.remainingPercent == 0
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(window.label).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(width: 56, alignment: .leading)
                TallyMeter(percent: window.remainingPercent, fill: running ? Palette.ember : Palette.ink,
                           uncertain: window.durationSeconds == nil || window.remainingPercent == nil, pace: limit == nil ? nil : pace)
                    .animation(.easeOut(duration: 0.7), value: window.remainingPercent)
                Text(window.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "?")
                    .font(.readout(13)).foregroundStyle(running ? Palette.ember : Palette.ink)
                    .lineLimit(1).fixedSize().frame(width: 50, alignment: .trailing)
                    .contentTransition(.numericText(value: window.remainingPercent ?? 0)).animation(.snappy, value: window.remainingPercent)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(window.label), \(window.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "unknown") remaining")
            if let reset = window.resetAt {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text((window.durationSeconds == nil ? "Duration unknown. " : "") + (reset <= now ? "Reset time passed; awaiting update" : "Resets in \(countdown(to: reset))"))
                        .foregroundStyle(Palette.dust).lineLimit(1)
                    if let limit {
                        Spacer(minLength: 4)
                        Label(limit <= now ? "Limit reached" : "Limit in \(countdown(to: limit))", systemImage: "flame.fill")
                            .labelStyle(.titleAndIcon).fontWeight(.semibold).lineLimit(1).fixedSize()
                            .foregroundStyle(Palette.ember)
                            .help("At your average rate, this window runs out before it resets. The tall mark shows where an even pace would put you.")
                    }
                }.font(.system(size: 11)).padding(.leading, 66)
            }
        }
    }

    private var pace: Double? {
        guard let reset = window.resetAt, let duration = window.durationSeconds, duration > 0 else { return nil }
        return min(100, max(0, reset.timeIntervalSince(now) / duration * 100))
    }

    private func countdown(to date: Date) -> String {
        let minutes = max(0, Int(ceil(date.timeIntervalSince(now) / 60)))
        if minutes >= 1440 { return "\(minutes / 1440)d \(minutes / 60 % 24)h" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
