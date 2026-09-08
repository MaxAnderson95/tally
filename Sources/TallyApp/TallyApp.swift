import AppKit
import SwiftUI
import TallyCore
import TallyHTTP
import Combine

@MainActor
final class Runtime: ObservableObject {
    @Published var snapshot: AccountsResponse?
    @Published var listenerError: String?
    @Published var refreshError: String?
    @Published var refreshSchedule: RefreshResponse?
    @Published var databasePath: String
    @Published var port: String
    @Published var webOrigin: String
    @Published var settingsError: String?
    @Published var storageError: String?
    let owner: TallyOwner
    private var serverTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var displayTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    init() {
        let settings = UserDefaults.standard
        let path = settings.string(forKey: "databasePath") ?? OpenCodeInventory.defaultPath()
        databasePath = path
        port = String(settings.object(forKey: "port") as? Int ?? 7483)
        webOrigin = settings.string(forKey: "webOrigin") ?? ""
        owner = TallyOwner(databasePath: path, appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development")
    }

    func start() {
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
                snapshot = await owner.snapshot()
                storageError = await owner.settingsError()?.message
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.owner.wake() }
        }
    }

    func refresh() async {
        do { refreshSchedule = try await owner.refresh(); refreshError = nil }
        catch let fault as Fault { refreshError = fault.message }
        catch { refreshError = "Refresh could not be scheduled." }
        snapshot = await owner.snapshot()
    }

    func startServer() {
        guard serverTask == nil else { return }
        guard let number = Int(port), (1024...65535).contains(number) else { listenerError = "Choose a port between 1024 and 65535."; return }
        if !webOrigin.isEmpty {
            guard let url = URL(string: webOrigin), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty else {
                listenerError = "Enter an HTTPS origin with no path, for example https://tally.example.ts.net."; return
            }
        }
        let policy = HTTPPolicy(port: number, webOrigin: webOrigin.isEmpty ? nil : webOrigin)
        let directory = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Web")
        listenerError = nil
        serverTask = Task {
            do { try await makeHTTPApplication(owner: owner, policy: policy, assetDirectory: directory).run() }
            catch { if !Task.isCancelled { listenerError = "Web/API unavailable on port \(number). Check the port and bundled assets, then retry." } }
            serverTask = nil
        }
    }

    func saveSettings() async {
        guard let number = Int(port), (1024...65535).contains(number) else { listenerError = "Choose a port between 1024 and 65535."; return }
        UserDefaults.standard.set(databasePath, forKey: "databasePath")
        UserDefaults.standard.set(number, forKey: "port")
        UserDefaults.standard.set(webOrigin, forKey: "webOrigin")
        do { try await owner.setDatabasePath(databasePath); settingsError = nil }
        catch let fault as Fault { settingsError = fault.message }
        catch { settingsError = "Cannot read the selected database." }
        snapshot = await owner.snapshot()
        let previous = serverTask; previous?.cancel(); await previous?.value
        startServer()
    }

    func pin(_ account: Account, move: Int? = nil) async {
        var ids = (snapshot?.accounts ?? []).filter(\.pinned).map(\.id)
        if let move, let index = ids.firstIndex(of: account.id) {
            let destination = index + move
            guard ids.indices.contains(destination) else { return }
            ids.swapAt(index, destination)
        } else if account.pinned { ids.removeAll { $0 == account.id } }
        else { ids.append(account.id) }
        do { try await owner.setPins(ids); settingsError = nil }
        catch let fault as Fault { settingsError = fault.message }
        catch { settingsError = "Cannot save pins." }
        snapshot = await owner.snapshot()
    }

    func stop() async {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        pollingTask?.cancel(); displayTask?.cancel(); serverTask?.cancel()
        await owner.shutdown()
        await pollingTask?.value; await displayTask?.value; await serverTask?.value
    }
}

struct Dashboard: View {
    @ObservedObject var runtime: Runtime
    @State private var settings = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Tally").font(.title2.bold())
                    Spacer()
                    Button("Refresh") { Task { await runtime.refresh() } }
                }
                if let updated = runtime.snapshot?.accounts.compactMap(\.latestObservation).max() {
                    Text("Updated \(updated.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                } else { Text("No successful reading yet").font(.caption).foregroundStyle(.secondary) }
                if let error = runtime.listenerError {
                    Text(error).font(.caption)
                    Button("Retry web/API") { runtime.startServer() }
                }
                if let error = runtime.refreshError { Text(error).font(.caption) }
                if let result = runtime.refreshSchedule {
                    Text("Refresh: \(result.accounts.map { $0.schedule.state }.joined(separator: ", ")). Activity: \(result.activity.state).")
                        .font(.caption).accessibilityLabel("Refresh scheduling result")
                }
                if let error = runtime.snapshot?.status.inventory.error { Text(error.message).font(.caption) }
                if runtime.snapshot?.accounts.isEmpty != false {
                    Text("No supported Accounts available. Manage Accounts and authentication in OpenCode, or check the database path in Settings.")
                }
                let accounts = runtime.snapshot?.accounts ?? []
                if accounts.contains(where: \.pinned) {
                    Text("Pinned").font(.caption).foregroundStyle(.secondary)
                    ForEach(accounts.filter(\.pinned)) { account in AccountCard(account: account) }
                }
                if accounts.contains(where: { !$0.pinned }) {
                    Text("Other accounts").font(.caption).foregroundStyle(.secondary)
                    ForEach(["anthropic", "openai", "opencode-go", "xai"], id: \.self) { provider in
                        let others = accounts.filter { !$0.pinned && $0.provider == provider }
                        if !others.isEmpty {
                            Text(ProviderArtwork.logos[provider]?.name ?? provider).font(.caption).foregroundStyle(.secondary)
                            ForEach(others) { account in AccountCard(account: account) }
                        }
                    }
                }
                Text("Recorded OpenCode activity").font(.headline)
                Text("Activity is not available in this build.").font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Button("Settings") { settings.toggle() }
                    Spacer()
                    Button("Quit Tally") { NSApplication.shared.terminate(nil) }
                }
                if settings {
                    TextField("OpenCode database path", text: $runtime.databasePath)
                    Text("Manage Account names and authentication in OpenCode.").font(.caption)
                    if let error = runtime.settingsError { Text(error).font(.caption) }
                    if let error = runtime.storageError { Text(error).font(.caption) }
                    ForEach(runtime.snapshot?.accounts ?? []) { account in
                        HStack {
                            Button(account.pinned ? "Unpin" : "Pin") { Task { await runtime.pin(account) } }
                            Text(account.name)
                            Spacer()
                            if account.pinned {
                                Button("↑") { Task { await runtime.pin(account, move: -1) } }.accessibilityLabel("Move \(account.name) earlier")
                                Button("↓") { Task { await runtime.pin(account, move: 1) } }.accessibilityLabel("Move \(account.name) later")
                            }
                        }
                    }
                    TextField("Loopback port", text: $runtime.port)
                    TextField("Allowed HTTPS web origin (optional)", text: $runtime.webOrigin)
                    Button("Save settings and restart listener") { Task { await runtime.saveSettings() } }
                }
            }.padding(12)
        }.frame(width: 360).frame(maxHeight: 650).background(scheme == .dark ? Color(red: 28/255, green: 28/255, blue: 30/255) : Color(red: 245/255, green: 245/255, blue: 247/255))
    }
}

struct AccountCard: View {
    let account: Account
    @State private var details = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                ProviderLogo(provider: account.provider, color: account.identityColorIndex)
                VStack(alignment: .leading) {
                    Text(account.name).font(.headline)
                    Text(account.groups.plan.data?.name ?? "Plan unknown").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if account.groups.quotas.stale || account.groups.quotas.data?.windows.contains(where: { $0.stale }) == true {
                    Image(systemName: "exclamationmark.triangle").accessibilityLabel("Stale reading")
                }
                if account.command.state != nil {
                    Button { details = true } label: { Image(systemName: "exclamationmark.triangle") }.help("Reset operation warning")
                }
                Button { details.toggle() } label: { Image(systemName: details ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.plain).accessibilityLabel("Details for \(account.name)")
            }
            let windows = account.overviewWindows
            if windows.isEmpty {
                Text("?").font(.system(size: 30, weight: .semibold))
                Rectangle().stroke(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(height: 4)
                Text(account.groups.quotas.observedAt == nil ? "Quota unavailable" : "No quota windows reported").font(.caption)
            }
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        if index == 0 && window.durationSeconds != nil {
                            Text(percent(window.remainingPercent)).font(.system(size: 30, weight: .semibold))
                            Text("\(window.label) remaining").font(.caption)
                            Spacer(minLength: 0)
                            Text(timing(window)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        } else {
                            Text(window.label).font(.subheadline)
                            Spacer()
                            Text(percent(window.remainingPercent)).font(.subheadline.weight(.semibold))
                        }
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.secondary.opacity(0.15))
                            if let remaining = window.remainingPercent { Rectangle().fill(.primary).frame(width: geometry.size.width * remaining / 100) }
                        }
                    }.frame(height: 4)
                        .overlay {
                            if window.durationSeconds == nil || window.remainingPercent == nil {
                                Rectangle().strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            }
                        }
                        .accessibilityLabel("\(percent(window.remainingPercent)) remaining")
                    if !(index == 0 && window.durationSeconds != nil) { Text(timing(window)).font(.caption).foregroundStyle(.secondary) }
                }
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
            if account.provider == "openai" { OpenAICreditDetails(account: account) }
            if details {
                if let state = account.command.state {
                    Text(state == "unknown" ? "Reset outcome unknown; acknowledgement required in Tally reset controls." : "Redeeming…").font(.caption)
                    Text(account.command.blockingOperationId ?? "").font(.caption).textSelection(.enabled)
                }
                AccountDetails(account: account)
            }
        }.padding(12).background(scheme == .dark ? Color(red: 44/255, green: 44/255, blue: 46/255) : .white, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.2)))
    }
    private func percent(_ number: Double?) -> String { number.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" } ?? "?" }
    private func money(_ money: Money?) -> String { money.map { "\($0.currency) \($0.amount)" } ?? "Unavailable" }
    private func extraLabel(_ extra: ExtraUsage?) -> String {
        switch extra?.presentation {
        case "off": "Off"
        case "used_only": "\(money(extra?.used)) used"
        case "bounded": "\(money(extra?.remaining)) remaining"
        default: "Unavailable"
        }
    }
    private func timing(_ window: QuotaWindow) -> String {
        let duration = window.durationSeconds == nil ? "Duration unknown. " : ""
        if window.resetState == "not_started" { return "Not started" }
        if window.resetState == "passed" { return duration + "Reset time passed; awaiting update" }
        guard let reset = window.resetAt else { return duration + "Reset time unavailable" }
        return duration + "Resets \(reset.formatted(.relative(presentation: .named)))"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let runtime = Runtime()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var pins: NSHostingView<MenuPins>!
    private var subscription: AnyCancellable?
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
        popover.contentViewController = NSHostingController(rootView: Dashboard(runtime: runtime))
        runtime.start()
    }
    private func layoutPins() {
        let size = pins.fittingSize
        item.length = size.width
        pins.frame = NSRect(x: 0, y: 0, width: size.width, height: NSStatusBar.system.thickness)
    }
    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
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
