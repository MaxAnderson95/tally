import AppKit
import ServiceManagement
import SwiftUI
import TallyCore

enum SettingsSection: Hashable { case menuBar, warmup, general }

struct TallySettings: View {
    @ObservedObject var runtime: Runtime
    @State var section = SettingsSection.menuBar
    private var accounts: [Account] { runtime.snapshot?.accounts ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            SlidingSegments(options: [(.menuBar, "Menu bar"), (.warmup, "Warm-up"), (.general, "General")], selection: $section)
                .frame(width: 300).padding(.top, 10).padding(.bottom, 12)
            Divider().overlay(Palette.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Group {
                        switch section {
                        case .menuBar: menuBar
                        case .warmup: warmup
                        case .general: general
                        }
                    }.transition(.opacity.combined(with: .offset(y: 6)))
                    if let error = runtime.storageError { Text(error).font(.system(size: 12)).foregroundStyle(Palette.ember) }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .background(Palette.ground).foregroundStyle(Palette.ink).font(.system(size: 13))
    }

    @ViewBuilder private var menuBar: some View {
        SettingsPanel(title: "Pinned accounts", footer: "Pinned accounts show their remaining percentages in the menu bar and sit at the top of the dashboard.") {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                let provider = ProviderArtwork.logos[account.provider]?.name ?? account.provider
                let siblings = accounts.filter { $0.pinned == account.pinned }
                if index > 0 { Divider().overlay(Palette.line) }
                HStack(spacing: 12) {
                    ProviderLogo(provider: account.provider, color: account.identityColorIndex, size: 15)
                        .frame(width: 28, height: 28).background(Palette.wash, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.name).fontWeight(.semibold)
                        Text(provider).font(.system(size: 11)).foregroundStyle(Palette.dust)
                    }
                    Spacer()
                    IconButton(symbol: "chevron.up", label: "Move \(provider) \(account.name) earlier") { Task { await runtime.move(account, by: -1) } }
                        .disabled(siblings.first?.id == account.id)
                    IconButton(symbol: "chevron.down", label: "Move \(provider) \(account.name) later") { Task { await runtime.move(account, by: 1) } }
                        .disabled(siblings.last?.id == account.id)
                    Toggle("Pin \(provider) \(account.name)", isOn: Binding(get: { account.pinned }, set: { _ in Task { await runtime.pin(account) } }))
                        .toggleStyle(TallySwitch(showsLabel: false)).padding(.leading, 6)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder private var warmup: some View {
        Text("Start five-hour windows before you sit down to code. Choose a model for each account you turn on.")
            .font(.system(size: 12)).foregroundStyle(Palette.dust).fixedSize(horizontal: false, vertical: true)
        ForEach(["anthropic", "openai", "opencode-go", "xai"], id: \.self) { provider in
            let matches = accounts.filter { $0.provider == provider }
            if !matches.isEmpty {
                SettingsPanel(title: ProviderArtwork.logos[provider]?.name ?? provider, logo: provider) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { Divider().overlay(Palette.line) }
                        WarmupSettings(account: account, runtime: runtime).padding(.horizontal, 14).padding(.vertical, 10)
                    }
                }
            }
        }
    }

    @ViewBuilder private var general: some View {
        SettingsPanel(title: "Startup") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(get: { runtime.loginEnabled }, set: { runtime.setLaunchAtLogin($0) })) {
                    Text("Launch at login").fontWeight(.semibold)
                }
                .toggleStyle(TallySwitch())
                .onAppear { runtime.readLoginStatus() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in runtime.readLoginStatus() }
                if let message = runtime.loginMessage {
                    Text(message).font(.system(size: 11)).foregroundStyle(Palette.dust).fixedSize(horizontal: false, vertical: true)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(QuietButtonStyle())
                }
            }.padding(14)
        }
        SettingsPanel(title: "OpenCode", footer: "Manage account names and sign-in in OpenCode.") {
            SettingsField(label: "Database", text: $runtime.databasePath).padding(14)
        }
        SettingsPanel(title: "Web access", footer: "Your phone reaches Tally through this port. Add your Tailscale HTTPS origin to allow it.") {
            VStack(spacing: 12) {
                SettingsField(label: "Port", text: $runtime.port)
                SettingsField(label: "HTTPS origin", text: $runtime.webOrigin, prompt: "Optional")
            }.padding(14)
        }
        HStack {
            if let error = runtime.settingsError { Text(error).font(.system(size: 12)).foregroundStyle(Palette.ember).fixedSize(horizontal: false, vertical: true) }
            Spacer()
            Button("Save changes") { Task { await runtime.saveSettings() } }.buttonStyle(QuietButtonStyle(prominent: true))
        }
    }
}

private struct SettingsPanel<Content: View>: View {
    let title: String
    var logo: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if let logo { ProviderLogo(provider: logo, color: 0, size: 12) }
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.dust)
            }.padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line))
            if let footer {
                Text(footer).font(.system(size: 11)).foregroundStyle(Palette.dust).padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsField: View {
    let label: String
    @Binding var text: String
    var prompt: String? = nil
    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.dust).frame(width: 90, alignment: .leading)
            TextField(label, text: $text, prompt: prompt.map { Text($0) })
                .textFieldStyle(.plain).labelsHidden()
                .padding(.horizontal, 10).frame(height: 30)
                .background(Palette.raised, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
        }
    }
}

/// A switch in Tally's palette whose thumb springs across.
struct TallySwitch: ToggleStyle {
    var showsLabel = true
    func makeBody(configuration: Configuration) -> some View {
        SwitchBody(configuration: configuration, showsLabel: showsLabel)
    }
    private struct SwitchBody: View {
        let configuration: Configuration
        let showsLabel: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var pressed = false
        var body: some View {
            HStack(spacing: 10) {
                if showsLabel {
                    configuration.label
                    Spacer(minLength: 0)
                }
                Capsule().fill(configuration.isOn ? Palette.active : Palette.spent)
                    .frame(width: 36, height: 21)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Capsule().fill(.white).shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                            .frame(width: pressed ? 21 : 17, height: 17).padding(2)
                    }
                    .opacity(enabled ? 1 : 0.45)
                    .animation(.spring(duration: 0.32, bounce: 0.35), value: configuration.isOn)
                    .animation(.spring(duration: 0.2), value: pressed)
                    .contentShape(Capsule())
                    .onTapGesture { if enabled { configuration.isOn.toggle() } }
                    .onLongPressGesture(minimumDuration: 10, pressing: { pressed = $0 && enabled }, perform: {})
            }
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
        }
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
            Toggle(isOn: Binding(get: { enabled }, set: { value in
                enabled = value
                if !value || models.contains(where: { $0.id == selected }) {
                    Task { await save() }
                }
            })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.name).fontWeight(.semibold)
                    Text(saving ? "Saving…" : enabled ? (!status.enabled ? "Choose a model" : status.needsAttention ? "Needs attention" : availability.reason != nil ? "Waiting" : "On") : "Off")
                        .font(.system(size: 11)).foregroundStyle(status.needsAttention && enabled ? Palette.ember : Palette.dust)
                        .contentTransition(.opacity)
                }
            }
            .toggleStyle(TallySwitch())
            .disabled(saving || (!enabled && availability.reason != nil))

            if let reason = availability.reason {
                Text(reason).font(.system(size: 11)).foregroundStyle(Palette.dust)
            }
            if enabled {
                if loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading models…").font(.system(size: 12)).foregroundStyle(Palette.dust)
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
                    .pickerStyle(.menu).fixedSize()
                    .disabled(saving || models.isEmpty || WarmupStatus.availability(quotas: account.groups.quotas, model: "").reason != nil)
                }
                if let error {
                    HStack(alignment: .top) {
                        Text(error).foregroundStyle(Palette.ember).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Retry") { Task { await loadModels() } }.buttonStyle(QuietButtonStyle()).disabled(loading)
                    }.font(.system(size: 11))
                } else if !status.enabled {
                    Text("Choose a model to start warming.").font(.system(size: 11)).foregroundStyle(Palette.dust)
                } else {
                    if status.needsAttention {
                        HStack(alignment: .top) {
                            Text(status.message).font(.system(size: 11)).foregroundStyle(Palette.ember).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Resume") { Task { await save() } }.buttonStyle(QuietButtonStyle())
                                .disabled(saving || loading || !models.contains(where: { $0.id == selected }))
                        }
                    }
                    schedule
                }
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.1), value: enabled)
        .animation(.easeOut(duration: 0.2), value: loading)
        .task(id: account.id) {
            selected = status.model
            enabled = status.enabled
            await loadModels()
        }
        .onChange(of: status.model) { _, model in selected = model }
        .onChange(of: status.enabled) { _, value in enabled = value }
    }

    @ViewBuilder private var schedule: some View {
        if status.needsAttention, let attempted = status.lastAttemptAt {
            Text("Last attempt: \(attempted.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11)).foregroundStyle(Palette.dust)
        } else if let next = status.nextAt, next > Date(), !status.needsAttention {
            Text("Next warm-up: \(next.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11)).foregroundStyle(Palette.dust)
        } else if let next = account.groups.quotas.nextAttemptAt, next > Date(), !status.needsAttention {
            Text("Next check: \(next.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11)).foregroundStyle(Palette.dust)
        } else if let observed = account.groups.quotas.observedAt {
            Text("Last checked: \(observed.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11)).foregroundStyle(Palette.dust)
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
