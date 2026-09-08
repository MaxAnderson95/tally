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
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.subheadline)
                Spacer()
                Text(window.remainingPercent.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" } ?? "?")
                    .font(.subheadline.weight(.semibold))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.secondary.opacity(0.15))
                    if let remaining = window.remainingPercent {
                        Rectangle().fill(limitDate == nil ? Color.blue : Color.red)
                            .frame(width: geometry.size.width * remaining / 100)
                    }
                    if limitDate != nil, let reset = window.resetAt, let duration = window.durationSeconds, duration > 0 {
                        let expectedRemaining = min(1, max(0, reset.timeIntervalSince(now) / duration))
                        RoundedRectangle(cornerRadius: 1).fill(.secondary)
                            .frame(width: 2, height: 10)
                            .position(x: geometry.size.width * expectedRemaining, y: geometry.size.height / 2)
                    }
                }
            }.frame(height: 4)
                .overlay {
                    if window.durationSeconds == nil || window.remainingPercent == nil {
                        Rectangle().strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                }
                .accessibilityLabel("\(window.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "?") remaining")
            if let reset = window.resetAt {
                HStack(alignment: .firstTextBaseline) {
                    let duration = window.durationSeconds == nil ? "Duration unknown. " : ""
                    Text(duration + (reset <= now ? "Reset time passed; awaiting update" : "Resets in \(countdown(to: reset))"))
                        .foregroundStyle(.secondary)
                    if let limit = limitDate {
                        Spacer(minLength: 4)
                        Label(limit <= now ? "Limit reached" : "Limit in \(countdown(to: limit))", systemImage: "flame.fill")
                            .foregroundStyle(.red)
                            .help("At your average usage rate, this quota is projected to run out before reset. The marker shows the remaining allowance at an even pace.")
                    }
                }.font(.caption)
            }
        }
    }

    private func countdown(to date: Date) -> String {
        let minutes = max(0, Int(ceil(date.timeIntervalSince(now) / 60)))
        if minutes >= 1440 { return "\(minutes / 1440)d \(minutes / 60 % 24)h" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
