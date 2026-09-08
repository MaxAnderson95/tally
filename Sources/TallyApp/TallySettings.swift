import AppKit
import ServiceManagement
import SwiftUI

struct TallySettings: View {
    @ObservedObject var runtime: Runtime

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Launch at login", isOn: Binding(get: { runtime.loginEnabled }, set: { runtime.setLaunchAtLogin($0) }))
                    .onAppear { runtime.readLoginStatus() }
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in runtime.readLoginStatus() }
                if let message = runtime.loginMessage {
                    Text(message).font(.caption)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
                TextField("OpenCode database path", text: $runtime.databasePath)
                Text("Manage Account names and authentication in OpenCode.").font(.caption)
                if let error = runtime.settingsError { Text(error).font(.caption) }
                if let error = runtime.storageError { Text(error).font(.caption) }
                let accounts = runtime.snapshot?.accounts ?? []
                ForEach(accounts) { account in
                    let provider = ProviderArtwork.logos[account.provider]?.name ?? account.provider
                    let hasMultipleAccounts = accounts.contains { $0.provider == account.provider && $0.id != account.id }
                    let label = hasMultipleAccounts ? "\(provider) - \(account.name)" : provider
                    HStack {
                        Button(account.pinned ? "Unpin" : "Pin") { Task { await runtime.pin(account) } }
                        Text(label)
                        Spacer()
                        if account.pinned {
                            Button("↑") { Task { await runtime.pin(account, move: -1) } }.accessibilityLabel("Move \(label) earlier")
                            Button("↓") { Task { await runtime.pin(account, move: 1) } }.accessibilityLabel("Move \(label) later")
                        }
                    }
                }
                TextField("Loopback port", text: $runtime.port)
                TextField("Allowed HTTPS web origin (optional)", text: $runtime.webOrigin)
                Button("Save settings and restart listener") { Task { await runtime.saveSettings() } }
            }.padding(20)
        }
    }
}
