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
        Text("Start five-hour windows before you sit down to code. Choose a model and optional daily start time for each account you turn on.")
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
        SettingsPanel(title: "Web access", footer: "Your phone reaches Tally through this port. Add the HTTPS origin of your tunnel or proxy to allow it. The web UI and API stay off until a password or token is set.") {
            VStack(spacing: 12) {
                SettingsField(label: "Port", text: $runtime.port)
                SettingsField(label: "HTTPS origin", text: $runtime.webOrigin, prompt: "Optional")
                SettingsField(label: "Password", text: $runtime.webPassword, prompt: "Browser sign-in", secure: true)
                SettingsField(label: "API token", text: $runtime.apiToken, prompt: "Bearer token for scripts", secure: true)
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
    var secure = false
    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.dust).frame(width: 90, alignment: .leading)
            Group {
                if secure { SecureField(label, text: $text, prompt: prompt.map { Text($0) }) }
                else { TextField(label, text: $text, prompt: prompt.map { Text($0) }) }
            }
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
    @State private var startTime: String?
    @State private var startTimeDirty = false
    @State private var enabled = false
    @State private var loading = true
    @State private var saving = false
    @State private var pendingSave: PendingSave?
    @State private var saveTask: Task<Void, Never>?
    @State private var error: String?

    private struct PendingSave {
        var full: (enabled: Bool, model: String)?
        var startTime: String??

        mutating func merge(_ next: PendingSave) {
            if let full = next.full { self.full = full }
            if let startTime = next.startTime { self.startTime = startTime }
        }
    }

    private var status: WarmupStatus { runtime.warmups[account.id] ?? WarmupStatus() }
    private var availability: WarmupAvailability { WarmupStatus.availability(quotas: account.groups.quotas, model: selected) }
    private var quotaUnavailable: Bool { WarmupStatus.availability(quotas: account.groups.quotas, model: "").reason != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { enabled }, set: { value in
                enabled = value
                if !value || models.contains(where: { $0.id == selected }) {
                    enqueueSave(PendingSave(full: (value, selected), startTime: startTimeDirty ? .some(startTime) : nil))
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
                        if models.contains(where: { $0.id == model }) {
                            enqueueSave(PendingSave(full: (true, model), startTime: startTimeDirty ? .some(startTime) : nil))
                        }
                    })) {
                        Text("Choose a model").tag("")
                        if !status.model.isEmpty && !models.contains(where: { $0.id == status.model }) {
                            Text(status.model + " (unavailable)").tag(status.model)
                        }
                        ForEach(models) { model in Text(model.name).tag(model.id) }
                    }
                    .pickerStyle(.menu).fixedSize()
                    .disabled(saving || models.isEmpty || quotaUnavailable)
                }
                HStack(spacing: 8) {
                    if let currentStartTime = startTime {
                        DatePicker("First warm-up", selection: startTimeBinding(currentStartTime), displayedComponents: .hourAndMinute)
                            .fixedSize()
                            .disabled(quotaUnavailable)
                        Button("Any time") {
                            updateStartTime(nil)
                        }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(saving || quotaUnavailable)
                    } else {
                        Text("First warm-up")
                        Text("Any time").foregroundStyle(Palette.dust)
                        Button("Set time") {
                            updateStartTime("04:00")
                        }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(saving || quotaUnavailable)
                    }
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
                            Button("Resume") {
                                enqueueSave(PendingSave(full: (true, selected), startTime: startTimeDirty ? .some(startTime) : nil))
                            }.buttonStyle(QuietButtonStyle())
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
            startTime = status.startTime
            startTimeDirty = false
            enabled = status.enabled
            await loadModels()
        }
        .onChange(of: status.model) { _, model in if !saving { selected = model } }
        .onChange(of: status.startTime) { _, value in if !saving && !startTimeDirty { startTime = value } }
        .onChange(of: status.enabled) { _, value in if !saving { enabled = value } }
    }

    private func updateStartTime(_ next: String?) {
        startTime = next
        if status.enabled {
            enqueueSave(PendingSave(full: nil, startTime: .some(next)))
        } else if models.contains(where: { $0.id == selected }) {
            enqueueSave(PendingSave(full: (true, selected), startTime: .some(next)))
        } else {
            startTimeDirty = true
        }
    }

    private func startTimeBinding(_ value: String) -> Binding<Date> {
        Binding(
            get: {
                let parts = WarmupStatus.parseStartTime(value) ?? (4, 0)
                let calendar = Calendar.current
                let year = calendar.component(.year, from: Date())
                // Use Jan 1 as a non-DST reference day so spring-forward hours like 02:30 do not shift in the picker.
                return calendar.date(from: DateComponents(year: year, month: 1, day: 1, hour: parts.hour, minute: parts.minute)) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                let formatted = WarmupStatus.formatStartTime(hour: components.hour ?? 4, minute: components.minute ?? 0)
                guard formatted != startTime else { return }
                updateStartTime(formatted)
            }
        )
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

    private func enqueueSave(_ next: PendingSave) {
        if var existing = pendingSave {
            existing.merge(next)
            pendingSave = existing
        } else {
            pendingSave = next
        }
        guard saveTask == nil else { return }
        saveTask = Task { await drainSaves() }
    }

    private func drainSaves() async {
        saving = true
        defer { saving = false; saveTask = nil }
        while let current = pendingSave {
            pendingSave = nil
            do {
                if let full = current.full {
                    if let nextStartTime = current.startTime {
                        try await runtime.owner.setWarmup(accountID: account.id, enabled: full.enabled, model: full.model, startTime: nextStartTime)
                        startTimeDirty = false
                    } else {
                        try await runtime.owner.setWarmup(accountID: account.id, enabled: full.enabled, model: full.model)
                    }
                } else if let nextStartTime = current.startTime {
                    try await runtime.owner.setWarmupStartTime(accountID: account.id, startTime: nextStartTime)
                    startTimeDirty = false
                }
                if pendingSave == nil {
                    runtime.warmups = await runtime.owner.warmupStatuses()
                    error = nil
                }
            } catch let fault as Fault {
                if pendingSave == nil {
                    error = fault.message
                    enabled = status.enabled
                    selected = status.model
                    startTime = status.startTime
                    startTimeDirty = false
                }
            } catch {
                if pendingSave == nil {
                    self.error = "Could not save warm-up preferences."
                    enabled = status.enabled
                    selected = status.model
                    startTime = status.startTime
                    startTimeDirty = false
                }
            }
        }
    }
}
