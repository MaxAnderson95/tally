import SwiftUI
import TallyCore

struct AccountDetails: View {
    let account: Account
    var now = Date()
    var body: some View {
        let groups = account.groups
        let errors = Set([groups.plan.error, groups.quotas.error, groups.extraUsage.error, groups.balances.error, groups.resetSummary.error, groups.resetDetails.error].compactMap { $0?.message })
        let windows = account.overviewWindows.filter { $0.resetAt != nil }
        VStack(alignment: .leading, spacing: 10) {
            ForEach(errors.sorted(), id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Palette.ember)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(windows) { window in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(window.label).foregroundStyle(Palette.dust).frame(width: 56, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Resets \(clockLabel(window.resetAt!, now: now))")
                        if !window.stale, window.resetAt! > now, let pacing = window.pacing {
                            Text(pacing.runOutAt.map { "At this pace, runs out \(clockLabel($0, now: now))" } ?? "At this pace, lasts until reset")
                                .foregroundStyle(Palette.dust)
                        }
                    }
                }
            }
            if account.overviewWindows.contains(where: { $0.pacing != nil }) {
                Text("Pace estimates assume your average usage rate continues.").foregroundStyle(Palette.dust)
            }
        }.font(.system(size: 11.5)).textSelection(.enabled)
    }
}
