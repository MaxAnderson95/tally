import SwiftUI
import TallyCore

struct OpenAICreditDetails: View {
    let account: Account
    @ObservedObject var runtime: Runtime
    @State var confirming: String?
    @State private var chosen: String?
    private var blocked: Bool {
        runtime.resetBusy.contains(account.id) || account.command.blockingOperationId != nil ||
        runtime.resetOperations[account.id].map { $0.state == .pending || $0.acknowledgementRequired } == true
    }
    var body: some View {
        let groups = account.groups
        VStack(alignment: .leading, spacing: 8) {
            Text((groups.resetSummary.data?.availableCount.map { "\($0) reset credits" } ?? "Reset count unavailable") + (groups.resetSummary.stale ? " (out of date)" : ""))
                .font(.system(size: 12, weight: .semibold))
            if let details = groups.resetDetails.data {
                if details.credits.isEmpty { Text("No reset credits reported").foregroundStyle(Palette.dust) }
                ForEach(details.credits) { credit in
                    Divider().overlay(Palette.line)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(credit.title ?? "Reset credit").fontWeight(.medium)
                                Text((credit.expiry.kind == "none" ? "No expiry" : credit.expiry.at.map { "Expires \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Expiry unknown") + (credit.isUsable ? "" : ", unavailable"))
                                    .foregroundStyle(Palette.dust)
                                if let description = credit.description { Text(description).foregroundStyle(Palette.dust).fixedSize(horizontal: false, vertical: true) }
                            }
                            Spacer(minLength: 0)
                            let operation = runtime.resetOperations[account.id]
                            if confirming != credit.id || blocked {
                                Button(blocked && (operation == nil ? chosen : operation?.selectedCreditId ?? operation?.requestedCreditId) == credit.id && operation?.acknowledgementRequired != true ? "Redeeming…" : "Use credit") { withAnimation(.spring(duration: 0.3, bounce: 0.15)) { confirming = credit.id } }
                                    .buttonStyle(QuietButtonStyle())
                                    .disabled(blocked || !credit.isUsable)
                            }
                        }
                        if confirming == credit.id && !blocked {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Use one credit on \(account.name)? This cannot be undone. OpenAI decides which windows reset.")
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    Spacer()
                                    Button("Cancel") { withAnimation(.spring(duration: 0.3, bounce: 0.15)) { confirming = nil } }.buttonStyle(QuietButtonStyle())
                                    Button("Use credit") {
                                        confirming = nil; chosen = credit.id
                                        Task { await runtime.redeem(account, credit: credit) }
                                    }.buttonStyle(QuietButtonStyle(prominent: true)).disabled(!credit.isUsable)
                                }
                            }
                            .padding(10)
                            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                        }
                    }
                }
            } else { Text("Credit list unavailable").foregroundStyle(Palette.dust) }
            Text("Using a credit asks for confirmation first.").foregroundStyle(Palette.dust)
        }.font(.system(size: 11.5))
    }
}
