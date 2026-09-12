import AppKit
import ServiceManagement
import SwiftUI
import TallyCore

struct TallySettings: View {
    @ObservedObject var runtime: Runtime
    private var accounts: [Account] { runtime.snapshot?.accounts ?? [] }

    var body: some View {
        TabView {
            Form {
                Section {
                    Text("Start five-hour windows before you sit down to code.")
                        .foregroundStyle(.secondary)
                }
                ForEach(["anthropic", "openai", "opencode-go", "xai"], id: \.self) { provider in
                    let matches = accounts.filter { $0.provider == provider }
                    if !matches.isEmpty {
                        Section(ProviderArtwork.logos[provider]?.name ?? provider) {
                            ForEach(matches) { account in
                                WarmupSettings(account: account, runtime: runtime)
                            }
                        }
                    }
                }
                if let error = runtime.storageError { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .tabItem { Label("Warm-up", systemImage: "sun.max") }

            Form {
                Section("Accounts in the menu bar") {
                    ForEach(accounts) { account in
                        let provider = ProviderArtwork.logos[account.provider]?.name ?? account.provider
                        let siblings = accounts.filter { $0.pinned == account.pinned }
                        HStack(spacing: 12) {
                            Toggle(isOn: Binding(get: { account.pinned }, set: { _ in Task { await runtime.pin(account) } })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name)
                                    Text(provider).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button { Task { await runtime.move(account, by: -1) } } label: { Image(systemName: "chevron.up") }
                                .disabled(siblings.first?.id == account.id)
                                .accessibilityLabel("Move \(provider) \(account.name) earlier")
                            Button { Task { await runtime.move(account, by: 1) } } label: { Image(systemName: "chevron.down") }
                                .disabled(siblings.last?.id == account.id)
                                .accessibilityLabel("Move \(provider) \(account.name) later")
                        }
                    }
                }
                if let error = runtime.storageError { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .tabItem { Label("Menu bar", systemImage: "menubar.rectangle") }

            Form {
                Section {
                    Toggle("Launch at login", isOn: Binding(get: { runtime.loginEnabled }, set: { runtime.setLaunchAtLogin($0) }))
                        .onAppear { runtime.readLoginStatus() }
                        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in runtime.readLoginStatus() }
                    if let message = runtime.loginMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Section("OpenCode") {
                    TextField("Database", text: $runtime.databasePath)
                    Text("Manage account names and sign-in in OpenCode.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Web access") {
                    TextField("Port", text: $runtime.port)
                    TextField("HTTPS origin", text: $runtime.webOrigin, prompt: Text("Optional"))
                }
                Section {
                    HStack {
                        Spacer()
                        Button("Save changes") { Task { await runtime.saveSettings() } }
                            .buttonStyle(.borderedProminent)
                    }
                    if let error = runtime.settingsError { Text(error).font(.caption).foregroundStyle(.red) }
                    if let error = runtime.storageError { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding(12)
    }
}

private struct WarmupSettings: View {
    let account: Account
    @ObservedObject var runtime: Runtime
    @State private var models: [WarmupModel] = []
    @State private var selected = ""
    @State private var enabled = false
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    private var status: WarmupStatus { runtime.warmups[account.id] ?? WarmupStatus() }
    private var availability: WarmupAvailability { WarmupStatus.availability(quotas: account.groups.quotas, model: selected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(account.name, isOn: Binding(get: { enabled && availability.reason == nil }, set: { value in
                enabled = value
                if !value || models.contains(where: { $0.id == selected }) {
                    Task { await save() }
                }
            }))
            .toggleStyle(.checkbox)
            .disabled(saving || availability.reason != nil)

            if let reason = availability.reason {
                Label(reason, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                if enabled && availability == .unknown { schedule }
            }
            if enabled && (availability.reason == nil || WarmupStatus.availability(quotas: account.groups.quotas, model: "").reason == nil) {
                if loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading models…").foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Model", selection: Binding(get: { selected }, set: { model in
                        selected = model
                        if models.contains(where: { $0.id == model }) { Task { await save() } }
                    })) {
                        Text("Choose a model").tag("")
                        if !status.model.isEmpty && !models.contains(where: { $0.id == status.model }) {
                            Text(status.model + " (unavailable)").tag(status.model)
                        }
                        ForEach(models) { model in Text(model.name).tag(model.id) }
                    }
                    .disabled(saving || models.isEmpty)
                }
                if let error {
                    HStack(alignment: .top) {
                        Text(error).foregroundStyle(.red)
                        Spacer()
                        Button("Retry") { Task { await loadModels() } }.disabled(loading)
                    }.font(.caption)
                } else if !status.enabled {
                    Text("Choose a model to start warming.").font(.caption).foregroundStyle(.secondary)
                } else {
                    if status.needsAttention {
                        Text(status.message).font(.caption).foregroundStyle(status.needsAttention ? .red : .secondary)
                    }
                    schedule
                }
            }
        }
        .task(id: account.id) {
            selected = status.model
            enabled = status.enabled
            await loadModels()
        }
    }

    @ViewBuilder private var schedule: some View {
        if let next = status.nextAt, next > Date(), !status.needsAttention {
            Text("Next warm-up: \(next.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        } else if let next = account.groups.quotas.nextAttemptAt, next > Date(), !status.needsAttention {
            Text("Next check: \(next.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        } else if let observed = account.groups.quotas.observedAt {
            Text("Last checked: \(observed.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func loadModels() async {
        loading = true
        defer { loading = false }
        do {
            models = try await runtime.owner.warmupModels(accountID: account.id)
            error = models.isEmpty ? "No language models are available for this account." : nil
        } catch is CancellationError { }
        catch let fault as Fault { error = fault.message }
        catch { self.error = "Could not load models from the provider." }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await runtime.owner.setWarmup(accountID: account.id, enabled: enabled, model: selected)
            runtime.warmups = await runtime.owner.warmupStatuses()
            error = nil
        } catch let fault as Fault { error = fault.message; enabled = status.enabled }
        catch { self.error = "Could not save warm-up preferences."; enabled = status.enabled }
    }
}
