import AppKit
import SwiftUI
import TallyCore
import TallyHTTP
import Combine
import ServiceManagement

@MainActor
final class Runtime: ObservableObject {
    @Published var snapshot: AccountsResponse?
    @Published var activity: ActivityResponse?
    @Published var activityRange = ActivityRange.today
    @Published var dashboardScrollPosition = ScrollPosition(edge: .top)
    @Published var listenerError: String?
    @Published var refreshError: String?
    @Published var databasePath: String
    @Published var port: String
    @Published var webOrigin: String
    @Published var settingsError: String?
    @Published var storageError: String?
    @Published var loginEnabled = false
    @Published var loginMessage: String?
    @Published var resetOperations: [String: Redemption] = [:]
    @Published var resetErrors: [String: String] = [:]
    @Published var resetBusy: Set<String> = []
    @Published var warmups: [String: WarmupStatus] = [:]
    let owner: TallyOwner
    private var serverTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var displayTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private let settings: UserDefaults
    private let assetDirectory: URL
    private var stopping = false

    init(owner: TallyOwner? = nil, settings: UserDefaults = .standard, assetDirectory: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Web")) {
        self.settings = settings
        self.assetDirectory = assetDirectory
        let path = settings.string(forKey: "databasePath") ?? OpenCodeInventory.defaultPath()
        databasePath = path
        port = String(settings.object(forKey: "port") as? Int ?? 7483)
        webOrigin = settings.string(forKey: "webOrigin") ?? ""
        self.owner = owner ?? TallyOwner(databasePath: path, appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development")
    }

    func start() {
        guard pollingTask == nil, !stopping else { return }
        if settings.object(forKey: "port") == nil { settings.set(Int(port), forKey: "port") }
        if !settings.bool(forKey: "loginSetupCompleted") { setLaunchAtLogin(true) }
        readLoginStatus()
        startServer()
        pollingTask = Task {
            await owner.wake()
            while !Task.isCancelled {
                await owner.tick()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        displayTask = Task {
            while !Task.isCancelled {
                await readResetState()
                activity = await owner.activityResponse(range: activityRange)
                storageError = await owner.settingsError()?.message
                warmups = await owner.warmupStatuses()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.owner.wake() }
        }
    }

    func readLoginStatus(_ status: SMAppService.Status = SMAppService.mainApp.status) {
        let approvalMessage = "Allow Tally in System Settings > General > Login Items."
        loginEnabled = status == .enabled || status == .requiresApproval
        if status == .requiresApproval {
            if loginMessage == nil { loginMessage = approvalMessage }
        } else if loginMessage == approvalMessage { loginMessage = nil }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            let service = SMAppService.mainApp
            if enabled && service.status != .enabled && service.status != .requiresApproval { try service.register() }
            if !enabled && service.status != .notRegistered { try service.unregister() }
            settings.set(true, forKey: "loginSetupCompleted")
            loginMessage = nil
        } catch { loginMessage = "Launch at login could not be changed: \(error.localizedDescription)" }
        readLoginStatus()
    }

    func refresh() async {
        do { _ = try await owner.refresh(); refreshError = nil }
        catch let fault as Fault { refreshError = fault.message }
        catch { refreshError = "Refresh could not be scheduled." }
        snapshot = await owner.snapshot()
    }

    func redeem(_ account: Account, credit: Credit) async {
        guard credit.isUsable, !resetBusy.contains(account.id), account.command.blockingOperationId == nil,
              resetOperations[account.id].map({ $0.state != .pending && !$0.acknowledgementRequired }) ?? true else { return }
        resetBusy.insert(account.id)
        defer { resetBusy.remove(account.id) }
        let id = UUID().uuidString
        do {
            resetOperations[account.id] = try await owner.submitRedemption(accountID: account.id, operationID: id, creditID: credit.id)
            resetErrors[account.id] = nil
        } catch let fault as Fault {
            resetErrors[account.id] = fault.message
            if let existing = try? await owner.redemption(operationID: fault.blockingOperationId ?? id) { resetOperations[account.id] = existing }
        } catch { resetErrors[account.id] = "Reset could not be submitted." }
        snapshot = await owner.snapshot()
    }

    func readResetState() async {
        snapshot = await owner.snapshot()
        for account in snapshot?.accounts ?? [] {
            guard !resetBusy.contains(account.id), let id = account.command.blockingOperationId ?? resetOperations[account.id]?.operationId else { continue }
            do {
                let operation = try await owner.redemption(operationID: id)
                if !resetBusy.contains(account.id) { resetOperations[account.id] = operation }
            } catch { resetErrors[account.id] = "Operation update unavailable. No reset will be resent." }
        }
    }

    func acknowledgeReset(_ account: Account) async {
        guard !resetBusy.contains(account.id), let operation = resetOperations[account.id], operation.acknowledgementRequired else { return }
        resetBusy.insert(account.id)
        defer { resetBusy.remove(account.id) }
        do {
            resetOperations[account.id] = try await owner.acknowledgeRedemption(operationID: operation.operationId)
            resetErrors[account.id] = nil
        } catch { resetErrors[account.id] = "Acknowledgement not confirmed. The warning and existing request are retained." }
        snapshot = await owner.snapshot()
    }

    func startServer() {
        guard serverTask == nil, !stopping else { return }
        guard validateListenerSettings() else { return }
        let number = Int(port)!
        let policy = HTTPPolicy(port: number, webOrigin: webOrigin.isEmpty ? nil : webOrigin)
        listenerError = nil
        serverTask = Task {
            do { try await makeHTTPApplication(owner: owner, policy: policy, assetDirectory: assetDirectory).run() }
            catch { if !Task.isCancelled { listenerError = "Web/API unavailable on port \(number). Check the port and bundled assets, then retry." } }
            serverTask = nil
        }
    }

    private func validateListenerSettings() -> Bool {
        guard let number = Int(port), (1024...65535).contains(number) else { listenerError = "Choose a port between 1024 and 65535."; return false }
        if !webOrigin.isEmpty {
            guard let url = URL(string: webOrigin), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty else {
                listenerError = "Enter an HTTPS origin with no path, for example https://tally.example.ts.net."; return false
            }
        }
        return true
    }

    func saveSettings() async {
        guard !stopping, validateListenerSettings(), let number = Int(port) else { return }
        settings.set(databasePath, forKey: "databasePath")
        settings.set(number, forKey: "port")
        settings.set(webOrigin, forKey: "webOrigin")
        do { try await owner.setDatabasePath(databasePath); settingsError = nil }
        catch let fault as Fault { settingsError = fault.message }
        catch { settingsError = "Cannot read the selected database." }
        snapshot = await owner.snapshot()
        let previous = serverTask; previous?.cancel(); await previous?.value
        startServer()
    }

    func pin(_ account: Account) async {
        var ids = (snapshot?.accounts ?? []).filter(\.pinned).map(\.id)
        if account.pinned { ids.removeAll { $0 == account.id } }
        else { ids.append(account.id) }
        do { try await owner.setPins(ids); settingsError = nil }
        catch let fault as Fault { settingsError = fault.message }
        catch { settingsError = "Cannot save pins." }
        snapshot = await owner.snapshot()
    }

    func move(_ account: Account, by offset: Int) async {
        var ids = (snapshot?.accounts ?? []).filter { $0.pinned == account.pinned }.map(\.id)
        guard let index = ids.firstIndex(of: account.id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        do {
            if account.pinned { try await owner.setPins(ids) }
            else { try await owner.setUnpinnedOrder(ids) }
            settingsError = nil
        } catch let fault as Fault { settingsError = fault.message }
        catch { settingsError = "Cannot save Account order." }
        snapshot = await owner.snapshot()
    }

    func setIdentityColor(_ account: Account, index: Int) async {
        do { try await owner.setIdentityColor(accountID: account.id, index: index); settingsError = nil }
        catch let fault as Fault { settingsError = fault.message }
        catch { settingsError = "Cannot save Account color." }
        snapshot = await owner.snapshot()
    }

    func stop() async {
        stopping = true
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        pollingTask?.cancel(); displayTask?.cancel(); serverTask?.cancel()
        await owner.shutdown()
        await pollingTask?.value; await displayTask?.value; await serverTask?.value
    }
}

struct Dashboard: View {
    @ObservedObject var runtime: Runtime
    let showSettings: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(nsImage: NSApplication.shared.applicationIconImage).resizable()
                        .frame(width: 24, height: 24).accessibilityHidden(true)
                    Text("Tally").font(.title2.bold())
                    Spacer()
                    if let updated = ((runtime.snapshot?.accounts.compactMap(\.latestObservation) ?? []) + [runtime.activity?.activity.observedAt].compactMap { $0 }).max() {
                        Text("Updated \(updated.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else { Text("No successful reading yet").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Button("Refresh") { Task { await runtime.refresh() } }
                }
                if let error = runtime.listenerError {
                    Text(error).font(.caption)
                    Button("Retry web/API") { runtime.startServer() }
                }
                if let error = runtime.refreshError { Text(error).font(.caption) }
                if let error = runtime.settingsError { Text(error).font(.caption) }
                if let error = runtime.snapshot?.status.inventory.error { Text(error.message).font(.caption) }
                if runtime.snapshot?.accounts.isEmpty != false {
                    Text("No supported Accounts available. Manage Accounts and authentication in OpenCode, or check the database path in Settings.")
                }
                let accounts = runtime.snapshot?.accounts ?? []
                if accounts.contains(where: \.pinned) {
                    Text("Pinned").font(.caption).foregroundStyle(.secondary)
                    ForEach(accounts.filter(\.pinned)) { account in AccountCard(account: account, runtime: runtime) }
                }
                let unpinned = accounts.filter { !$0.pinned }
                ForEach(Array(unpinned.enumerated()), id: \.element.id) { index, account in
                    if index == 0 || unpinned[index - 1].provider != account.provider {
                        Text(ProviderArtwork.logos[account.provider]?.name ?? account.provider).font(.caption).foregroundStyle(.secondary)
                    }
                    AccountCard(account: account, runtime: runtime)
                }
                RecordedActivity(runtime: runtime)
                Divider()
                HStack {
                    Button("Settings", action: showSettings)
                    Spacer()
                    Button("Quit Tally") { NSApplication.shared.terminate(nil) }
                }
            }.padding(12)
        }.scrollPosition($runtime.dashboardScrollPosition)
            .frame(width: 360).background(scheme == .dark ? Color(red: 28/255, green: 28/255, blue: 30/255) : Color(red: 245/255, green: 245/255, blue: 247/255))
    }
}

struct AccountCard: View {
    let account: Account
    @ObservedObject var runtime: Runtime
    @State private var details = false
    @State var resetExplanation = false
    @State private var choosingColor = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Button { choosingColor.toggle() } label: {
                    ProviderLogo(provider: account.provider, color: account.identityColorIndex)
                }.buttonStyle(.plain)
                    .accessibilityLabel("Change icon color for \(account.name)")
                    .popover(isPresented: $choosingColor) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Icon color").font(.headline)
                            HStack(spacing: 8) {
                                ForEach(ProviderArtwork.light.indices, id: \.self) { index in
                                    Button {
                                        Task { await runtime.setIdentityColor(account, index: index) }
                                        choosingColor = false
                                    } label: {
                                        ProviderLogo(provider: account.provider, color: index, size: 22)
                                            .padding(6)
                                            .background(account.identityColorIndex == index ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                    }.buttonStyle(.plain)
                                        .accessibilityLabel(["Monochrome", "Blue", "Orange", "Green", "Purple", "Pink"][index])
                                        .accessibilityAddTraits(account.identityColorIndex == index ? .isSelected : [])
                                }
                            }
                        }.padding(12)
                    }
                HStack(alignment: .firstTextBaseline) {
                    Text(account.name).font(.headline)
                    Text(account.groups.plan.data?.name ?? "Plan unknown").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if account.groups.quotas.stale || account.groups.quotas.data?.windows.contains(where: { $0.stale }) == true {
                    Image(systemName: "exclamationmark.triangle")
                        .help(quotaWarning)
                        .accessibilityLabel(quotaWarning)
                }
                if account.command.acknowledgementRequired || runtime.resetOperations[account.id]?.acknowledgementRequired == true {
                    Button { resetExplanation.toggle() } label: { Image(systemName: "exclamationmark.triangle") }
                        .accessibilityLabel("Unknown reset outcome for \(account.name)")
                        .help("The reset outcome is unknown. Click to review and acknowledge it before using another credit.")
                }
                Button { details.toggle() } label: { Image(systemName: details ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.plain).accessibilityLabel("Details for \(account.name)")
            }
            if let operation = runtime.resetOperations[account.id], operation.state != .pending,
               !operation.acknowledgementRequired || resetExplanation {
                VStack(alignment: .leading, spacing: 8) {
                    Text(operation.displayMessage(for: account))
                    if operation.acknowledgementRequired {
                        Button("Acknowledge") { Task { await runtime.acknowledgeReset(account) } }
                            .disabled(runtime.resetBusy.contains(account.id))
                    }
                }.font(.caption).accessibilityElement(children: .contain)
            } else if resetExplanation && account.command.acknowledgementRequired {
                Text("Outcome unknown. Reading the existing operation before acknowledgement.").font(.caption)
            }
            if let error = runtime.resetErrors[account.id] { Text(error).font(.caption) }
            let windows = account.overviewWindows
            if windows.isEmpty {
                Text("?").font(.system(size: 30, weight: .semibold))
                Rectangle().stroke(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(height: 4)
                Text(account.groups.quotas.observedAt == nil ? "Quota unavailable" : "No quota windows reported").font(.caption)
            }
            ForEach(windows) { window in
                QuotaRow(window: window)
            }
            if account.provider == "anthropic" || account.provider == "xai" {
                let extra = account.groups.extraUsage
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(account.provider == "xai" ? "PAYG" : "Extra usage")
                        Spacer()
                        Text(extraLabel(extra.data)).multilineTextAlignment(.trailing)
                    }.font(.subheadline)
                    if let data = extra.data, data.presentation == "bounded" {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.secondary.opacity(0.15))
                                Rectangle().fill(.primary).frame(width: geometry.size.width * (data.remainingPercent ?? 0) / 100)
                            }
                        }.frame(height: 4)
                        Text("\(money(data.used)) used of \(money(data.limit))").font(.caption)
                    }
                    if extra.stale { Text(account.provider == "xai" ? "PAYG stale" : "Extra usage stale").font(.caption) }
                }
            }
            if account.provider == "openai" { OpenAICreditDetails(account: account, runtime: runtime) }
            if let warmup = runtime.warmups[account.id], warmup.needsAttention {
                Label("Auto warm-up: " + warmup.message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if details {
                if let state = account.command.state {
                    Text(state == "unknown" ? "Outcome unknown; open the card-header warning to acknowledge." : "Redeeming…").font(.caption)
                    Text(account.command.blockingOperationId ?? "").font(.caption).textSelection(.enabled)
                }
                AccountDetails(account: account)
            }
        }.padding(12).background(scheme == .dark ? Color(red: 44/255, green: 44/255, blue: 46/255) : .white, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.2)))
    }
    private var quotaWarning: String {
        let quotas = account.groups.quotas
        var reasons: [String] = []
        if let error = quotas.error ?? runtime.snapshot?.status.inventory.error { reasons.append(error.message) }
        if quotas.stale {
            reasons.append(quotas.observedAt.map { "Showing an older reading from \($0.formatted(date: .abbreviated, time: .standard))." } ?? "No successful quota reading yet.")
        }
        for window in quotas.data?.windows ?? [] where window.resetState == "passed" {
            reasons.append("\(window.label): reset time passed; awaiting an updated reading.")
        }
        return reasons.joined(separator: "\n")
    }
    private func money(_ money: Money?) -> String { money.map { "\($0.currency) \($0.amount)" } ?? "Unavailable" }
    private func extraLabel(_ extra: ExtraUsage?) -> String {
        switch extra?.presentation {
        case "off": "Off"
        case "used_only": "\(money(extra?.used)) used"
        case "bounded": "\(money(extra?.remaining)) remaining"
        default: "Unavailable"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let runtime = Runtime()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var pins: NSHostingView<MenuPins>!
    private var subscription: AnyCancellable?
    private var settingsWindow: NSWindow?
    private var outsideClickMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        pins = NSHostingView(rootView: MenuPins(runtime: runtime))
        pins.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(togglePopover)))
        item.button?.addSubview(pins)
        item.button?.setAccessibilityLabel("Tally")
        subscription = runtime.$snapshot.sink { [weak self] _ in
            Task { @MainActor in self?.layoutPins() }
        }
        item.button?.target = self; item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: Dashboard(runtime: runtime, showSettings: { [weak self] in self?.showSettings() }))
        runtime.start()
    }
    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Tally Settings"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 500, height: 420)
            window.contentViewController = NSHostingController(rootView: TallySettings(runtime: runtime))
            window.center()
            settingsWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func layoutPins() {
        let size = pins.fittingSize
        item.length = size.width
        pins.frame = NSRect(x: 0, y: 0, width: size.width, height: NSStatusBar.system.thickness)
    }
    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            if let screen = button.window?.screen ?? NSScreen.main {
                popover.contentSize = NSSize(width: 360, height: screen.frame.height * 0.8)
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    func applicationDidResignActive(_ notification: Notification) {
        popover.performClose(nil)
    }
    func popoverDidShow(_ notification: Notification) {
        runtime.dashboardScrollPosition.scrollTo(edge: .top)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.popover.close()
        }
    }
    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await runtime.stop(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main
struct TallyApp {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--collect-once") {
            let owner = TallyOwner(databasePath: UserDefaults.standard.string(forKey: "databasePath") ?? OpenCodeInventory.defaultPath(), appBuild: "read-only-check")
            do { try await owner.refresh(); await owner.waitForCollection() } catch {}
            let snapshot = await owner.snapshot()
            if let data = try? Wire.encoder().encode(snapshot) { FileHandle.standardOutput.write(data) }
            await owner.shutdown()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
