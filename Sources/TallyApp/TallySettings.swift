import AppKit
import ServiceManagement
import SwiftUI
import TallyCore

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
                    let siblings = accounts.filter { $0.pinned == account.pinned }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button(account.pinned ? "Unpin" : "Pin") { Task { await runtime.pin(account) } }
                            Text(label)
                            Spacer()
                            Button("↑") { Task { await runtime.move(account, by: -1) } }
                                .accessibilityLabel("Move \(label) earlier").disabled(siblings.first?.id == account.id)
                            Button("↓") { Task { await runtime.move(account, by: 1) } }
                                .accessibilityLabel("Move \(label) later").disabled(siblings.last?.id == account.id)
                        }
                        WarmupSettings(account: account, runtime: runtime)
                    }
                }
                TextField("OpenCode V2 executable", text: $runtime.warmupExecutable)
                TextField("Installed Claude auth plugin directory", text: $runtime.warmupAuthPlugin)
                Text("Warm-up uses a private OpenCode server. Claude requires your installed subscription auth plugin. Save execution settings before loading models.").font(.caption)
                TextField("Loopback port", text: $runtime.port)
                TextField("Allowed HTTPS web origin (optional)", text: $runtime.webOrigin)
                Button("Save settings and restart listener") { Task { await runtime.saveSettings() } }
            }.padding(20)
        }
    }
}

private struct WarmupSettings: View {
    let account: Account
    @ObservedObject var runtime: Runtime
    @State private var models: [WarmupModel] = []
    @State private var selected = ""
    @State private var loading = false
    @State private var error: String?

    private var status: WarmupStatus { runtime.warmups[account.id] ?? WarmupStatus() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Auto warm-up", isOn: Binding(get: { status.enabled }, set: { enabled in
                    Task { await save(enabled: enabled) }
                })).disabled(!status.enabled && !models.contains(where: { $0.id == selected }))
                Button(loading ? "Loading…" : "Load models") {
                    Task {
                        loading = true
                        defer { loading = false }
                        do {
                            models = try await runtime.owner.warmupModels(accountID: account.id)
                            error = models.isEmpty ? "No models available for this Account." : nil
                        } catch let fault as Fault { error = fault.message }
                        catch { self.error = "Could not load models from OpenCode." }
                    }
                }.disabled(loading)
            }
            Picker("Warm-up model", selection: $selected) {
                Text("Choose a model").tag("")
                if !status.model.isEmpty && !models.contains(where: { $0.id == status.model }) {
                    Text(status.model + " (reload to verify)").tag(status.model)
                }
                ForEach(models) { model in Text(model.name).tag(model.id) }
            }
            .onAppear { selected = status.model }
            .onChange(of: status.model) { _, model in selected = model }
            .onChange(of: selected) { _, _ in
                if models.contains(where: { $0.id == selected }), status.enabled { Task { await save(enabled: true) } }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if status.enabled {
                Text(status.message).font(.caption)
                if let next = status.nextAt { Text("Next: \(next.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                Text("One short prompt after reset, delayed up to 20 minutes. Uses subscription allowance while Tally is running and the Mac is awake. Timing and prompt variation do not guarantee provider approval.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func save(enabled: Bool) async {
        do {
            try await runtime.owner.setWarmup(accountID: account.id, enabled: enabled, model: selected)
            runtime.warmups = await runtime.owner.warmupStatuses()
            error = nil
        } catch let fault as Fault { error = fault.message }
        catch { self.error = "Could not save warm-up preferences." }
    }
}
