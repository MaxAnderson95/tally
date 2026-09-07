import AppKit
import SwiftUI
import TallyCore
import TallyHTTP

@MainActor
final class Runtime: ObservableObject {
    @Published var snapshot: AccountsResponse?
    @Published var listenerError: String?
    @Published var refreshError: String?
    @Published var databasePath: String
    @Published var port: String
    @Published var webOrigin: String
    @Published var settingsError: String?
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
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(120)) } catch { break }
            }
        }
        displayTask = Task {
            while !Task.isCancelled {
                snapshot = await owner.snapshot()
                if let error = await owner.settingsError() { settingsError = error.message }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        do { try await owner.refresh(); refreshError = nil }
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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Tally").font(.title2.bold())
                    Spacer()
                    Button("Refresh") { Task { await runtime.refresh() } }
                }
                if let updated = runtime.snapshot?.accounts.compactMap({ $0.groups.quotas.observedAt }).max() {
                    Text("Updated \(updated.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                } else { Text("No successful reading yet").font(.caption).foregroundStyle(.secondary) }
                if let error = runtime.listenerError {
                    Text(error).font(.caption)
                    Button("Retry web/API") { runtime.startServer() }
                }
                if let error = runtime.refreshError { Text(error).font(.caption) }
                if runtime.snapshot?.accounts.isEmpty != false {
                    Text("No supported Accounts available. Manage Accounts and authentication in OpenCode, or check the database path in Settings.")
                }
                ForEach(runtime.snapshot?.accounts ?? []) { account in AccountCard(account: account) }
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
            }.padding(18)
        }.frame(width: 360).frame(maxHeight: 650)
    }
}

struct AccountCard: View {
    let account: Account
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                if account.provider == "opencode-go" {
                    GoLogo().fill(style: FillStyle(eoFill: true)).frame(width: 22, height: 22).accessibilityLabel("OpenCode Go")
                } else { Text(account.provider).font(.caption) }
                VStack(alignment: .leading) {
                    Text(account.name).font(.headline)
                    Text(account.groups.plan.data?.name ?? "Plan unknown").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if account.groups.quotas.stale || account.groups.quotas.data?.windows.contains(where: { $0.stale }) == true {
                    Image(systemName: "exclamationmark.triangle").accessibilityLabel("Stale reading")
                }
            }
            let windows = account.groups.quotas.data?.windows ?? []
            if windows.isEmpty {
                Text("?").font(.system(size: 30, weight: .semibold))
                Text(account.groups.quotas.observedAt == nil ? "Quota unavailable" : "No quota windows reported").font(.caption)
            }
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        if index == 0 && window.durationSeconds != nil {
                            Text(percent(window.remainingPercent)).font(.system(size: 30, weight: .semibold))
                            Text("\(window.label) remaining").font(.caption)
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
                                Rectangle().stroke(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).padding(-2)
                            }
                        }
                        .accessibilityLabel("\(percent(window.remainingPercent)) remaining")
                    Text(timing(window)).font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Details") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow { Text("Observed"); Text(account.groups.quotas.observedAt?.formatted() ?? "Never") }
                    GridRow { Text("Timezone"); Text(TimeZone.current.identifier) }
                    if let error = account.groups.quotas.error { GridRow { Text("Error"); Text(error.message) } }
                    ForEach(windows) { window in
                        GridRow { Text("\(window.label) reset"); Text(window.resetAt?.formatted() ?? "Unavailable") }
                    }
                }.font(.caption).padding(.top, 8)
            }.font(.caption)
        }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.2)))
    }
    private func percent(_ number: Double?) -> String { number.map { "\(Int($0.rounded()))%" } ?? "?" }
    private func timing(_ window: QuotaWindow) -> String {
        let duration = window.durationSeconds == nil ? "Duration unknown. " : ""
        if window.resetState == "passed" { return duration + "Reset time passed; awaiting update" }
        guard let reset = window.resetAt else { return duration + "Reset time unavailable" }
        return duration + "Resets \(reset.formatted(.relative(presentation: .named)))"
    }
}

struct GoLogo: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let scale = rect.width / 24
        path.addRect(CGRect(x: 3 * scale, y: 3 * scale, width: 18 * scale, height: 18 * scale))
        path.addRect(CGRect(x: 7 * scale, y: 7 * scale, width: 10 * scale, height: 10 * scale))
        path.addRect(CGRect(x: 13 * scale, y: 9 * scale, width: 2 * scale, height: 6 * scale))
        return path
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let runtime = Runtime()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "chart.bar", accessibilityDescription: "Tally")
        item.button?.target = self; item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: Dashboard(runtime: runtime))
        runtime.start()
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
