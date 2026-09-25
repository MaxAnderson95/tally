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
    private var outcomeShownAt: [String: Date] = [:]
    // Not @Published: the popover reads nothing from it, and publishing would re-evaluate every view on open and close.
    var dashboardVisible = false
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
            // Countdowns, pacing, and relative times display at minute granularity, so one unconditional
            // publish per minute refreshes them; every other second publishes only changed state.
            var iteration = 0
            while !Task.isCancelled {
                await refreshDisplay(force: iteration % 60 == 0)
                iteration += 1
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

    func refreshDisplay(force: Bool, now: Date = Date()) async {
        let next = await owner.snapshot()
        if force || snapshot.map({ next.differs(from: $0) }) ?? true { snapshot = next }
        for account in next.accounts {
            guard !resetBusy.contains(account.id), let id = account.command.blockingOperationId ?? resetOperations[account.id]?.operationId else { continue }
            do {
                let operation = try await owner.redemption(operationID: id)
                guard !resetBusy.contains(account.id) else { continue }
                if resetOperations[account.id] != operation { resetOperations[account.id] = operation; outcomeShownAt[account.id] = nil }
                guard operation.state != .pending, !operation.acknowledgementRequired else { continue }
                // A settled outcome is transient feedback, not a persistent status. The window runs only while
                // the popover is open, because the display loop keeps ticking when it is closed and a delayed
                // journal recovery can settle an outcome hours after the reset. Anchoring the window to the
                // owner's updatedAt, or to an observation nobody could see, expires the confirmation unseen.
                // Releasing the entry also stops re-reading a finished operation.
                guard dashboardVisible else { continue }
                let shownAt = outcomeShownAt[account.id] ?? now
                outcomeShownAt[account.id] = shownAt
                if now.timeIntervalSince(shownAt) >= 10 { resetOperations[account.id] = nil; outcomeShownAt[account.id] = nil }
            } catch { resetErrors[account.id] = "Operation update unavailable. No reset will be resent." }
        }
        let activity = await owner.activityResponse(range: activityRange)
        if force || self.activity.map({ activity.differs(from: $0) }) ?? true { self.activity = activity }
        let error = await owner.settingsError()?.message
        if error != storageError { storageError = error }
        let statuses = await owner.warmupStatuses()
        if statuses != warmups { warmups = statuses }
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

    @Published var switchingAccount: String?

    func activate(_ account: Account) async {
        guard switchingAccount == nil else { return }
        switchingAccount = account.id
        defer { switchingAccount = nil }
        do { snapshot = try await owner.activate(accountID: account.id); settingsError = nil }
        catch let fault as Fault { settingsError = fault.message; snapshot = await owner.snapshot() }
        catch { settingsError = "Account switch was not confirmed. Refresh Accounts before trying again." }
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

// Every @Published assignment re-evaluates every observing view, including the hidden popover and
// the retained Settings window, and the SwiftUI Observation trackings those evaluations create are
// never released while nothing tracked changes. The display loop therefore publishes only real
// changes. serverTime and pacing follow the clock and would differ every second; the once-a-minute
// forced publish refreshes their displays instead.
private extension AccountsResponse {
    func differs(from other: Self) -> Bool { clockless != other.clockless }
    private var clockless: Self {
        var copy = self
        copy.status.serverTime = .distantPast
        for account in copy.accounts.indices {
            for window in copy.accounts[account].groups.quotas.data?.windows.indices ?? 0..<0 {
                copy.accounts[account].groups.quotas.data?.windows[window].pacing = nil
            }
        }
        return copy
    }
}
private extension ActivityResponse {
    func differs(from other: Self) -> Bool {
        var same = other; same.status.serverTime = status.serverTime
        return self != same
    }
}

enum DashboardView: Hashable { case accounts, activity }

struct Dashboard: View {
    @ObservedObject var runtime: Runtime
    let showSettings: () -> Void
    @State private var view = DashboardView.accounts
    @State private var refreshing = false
    var body: some View {
        let accounts = runtime.snapshot?.accounts ?? []
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(nsImage: NSApplication.shared.applicationIconImage).resizable()
                        .frame(width: 22, height: 22).accessibilityHidden(true)
                    Text("Tally").font(.system(size: 15, weight: .bold))
                    Spacer(minLength: 8)
                    Group {
                        if let updated = (accounts.compactMap(\.latestObservation) + [runtime.activity?.activity.observedAt].compactMap { $0 }).max() {
                            Text("Updated \(updated.formatted(.relative(presentation: .named)))")
                        } else { Text("No reading yet") }
                    }.font(.system(size: 11)).foregroundStyle(Palette.dust).lineLimit(1)
                    IconButton(symbol: "arrow.clockwise", label: "Refresh", spinning: refreshing) {
                        guard !refreshing else { return }
                        refreshing = true
                        Task { await runtime.refresh(); refreshing = false }
                    }
                    IconButton(symbol: "slider.horizontal.3", label: "Settings", action: showSettings)
                }
                SlidingSegments(options: [(.accounts, accounts.isEmpty ? "Accounts" : "Accounts  \(accounts.count)"), (.activity, "Activity")], selection: $view)
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
            Divider().overlay(Palette.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    notices
                    Group {
                        if view == .accounts { VStack(alignment: .leading, spacing: 16) { accountList(accounts) } }
                        else { RecordedActivity(runtime: runtime) }
                    }.transition(.opacity.combined(with: .offset(y: 6)))
                }.padding(14)
            }
            // A mouse's always-visible scroller takes width only while content overflows, which shifts the whole popover sideways.
            .scrollIndicators(.never)
            .scrollPosition($runtime.dashboardScrollPosition)
            Divider().overlay(Palette.line)
            HStack {
                Spacer()
                Button("Quit Tally") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.dust)
            }.padding(.horizontal, 14).padding(.vertical, 9)
        }
        .frame(width: 360).background(Palette.ground).foregroundStyle(Palette.ink)
    }

    @ViewBuilder private var notices: some View {
        let messages = [runtime.refreshError, runtime.settingsError, runtime.snapshot?.status.inventory.error?.message].compactMap { $0 }
        if runtime.listenerError != nil || !messages.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let error = runtime.listenerError {
                    HStack(alignment: .firstTextBaseline) {
                        Text(error)
                        Spacer()
                        Button("Retry") { runtime.startServer() }.buttonStyle(QuietButtonStyle())
                    }
                }
                ForEach(messages, id: \.self) { Text($0) }
            }
            .font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.ember.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder private func accountList(_ accounts: [Account]) -> some View {
        if accounts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No accounts yet").font(.system(size: 17, weight: .semibold))
                Text("Sign in to Anthropic, OpenAI, OpenCode Go, or xAI in OpenCode and they appear here. If you already have, check the database path in Settings.")
                    .font(.system(size: 12)).foregroundStyle(Palette.dust).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            let pinned = accounts.filter(\.pinned)
            let others = accounts.filter { !$0.pinned }
            if !pinned.isEmpty { ledger("Pinned", pinned) }
            if !others.isEmpty { ledger(pinned.isEmpty ? "Accounts" : "Other accounts", others) }
        }
    }

    private func ledger(_ title: String, _ accounts: [Account]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.dust).padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 { Divider().overlay(Palette.line) }
                    AccountCard(account: account, runtime: runtime)
                }
            }
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line))
        }
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    var spinning = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: spinning)
                .frame(width: 26, height: 26)
                .background(hovering ? Palette.spent : Palette.wash, in: Circle())
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.15), value: hovering)
        }.buttonStyle(PressableStyle()).help(label).accessibilityLabel(label).onHover { hovering = $0 }
    }
}

struct AccountCard: View {
    let account: Account
    @ObservedObject var runtime: Runtime
    @State private var details = false
    @State var resetExplanation = false
    @State private var choosingColor = false
    var body: some View {
        let provider = ProviderArtwork.logos[account.provider]?.name ?? account.provider
        let plan = account.groups.plan.data?.name
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { choosingColor.toggle() } label: {
                    ProviderLogo(provider: account.provider, color: account.identityColorIndex, size: 15)
                        .frame(width: 26, height: 26).background(Palette.wash, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
                    .accessibilityLabel("Change icon color for \(account.name)")
                    .popover(isPresented: $choosingColor) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Icon color").font(.system(size: 12, weight: .semibold))
                            HStack(spacing: 4) {
                                ForEach(ProviderArtwork.light.indices, id: \.self) { index in
                                    Button {
                                        Task { await runtime.setIdentityColor(account, index: index) }
                                        choosingColor = false
                                    } label: {
                                        ProviderLogo(provider: account.provider, color: index, size: 18)
                                            .frame(width: 32, height: 32)
                                            .background(account.identityColorIndex == index ? Palette.spent : .clear, in: RoundedRectangle(cornerRadius: 8))
                                    }.buttonStyle(.plain)
                                        .accessibilityLabel(["Monochrome", "Blue", "Orange", "Green", "Purple", "Pink"][index])
                                        .accessibilityAddTraits(account.identityColorIndex == index ? .isSelected : [])
                                }
                            }
                        }.padding(12)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text(plan.map { provider.lowercased().hasSuffix($0.lowercased()) ? provider : "\(provider) \($0)" } ?? "\(provider) plan unknown")
                        .font(.system(size: 11)).foregroundStyle(Palette.dust).lineLimit(1)
                }
                Spacer(minLength: 6)
                QuotaWarning(account: account, inventoryError: runtime.snapshot?.status.inventory.error).foregroundStyle(Palette.ember)
                if account.command.acknowledgementRequired || runtime.resetOperations[account.id]?.acknowledgementRequired == true {
                    Button { resetExplanation.toggle() } label: { Image(systemName: "exclamationmark.triangle").frame(width: 20, height: 20) }
                        .buttonStyle(.plain).foregroundStyle(Palette.ember)
                        .accessibilityLabel("Unknown reset outcome for \(account.name)")
                        .help("The reset outcome is unknown. Review and acknowledge it before using another credit.")
                }
                if account.active == true {
                    Label("Active", systemImage: "circle.fill").labelStyle(ActiveLabelStyle())
                        .help("Active in OpenCode").accessibilityLabel("Active in OpenCode")
                } else {
                    Button(runtime.switchingAccount == account.id ? "Switching…" : "Use in OpenCode") { Task { await runtime.activate(account) } }
                        .buttonStyle(QuietButtonStyle()).lineLimit(1).fixedSize().disabled(runtime.switchingAccount != nil || account.active == nil)
                        .help(account.active == nil ? "Selection unavailable" : "Make this the account OpenCode uses")
                }
            }
            resetNotes
            let windows = account.overviewWindows
            if windows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    TallyMeter(percent: nil, uncertain: true)
                    Text(account.groups.quotas.observedAt == nil ? "Quota unavailable" : "No quota windows reported").font(.system(size: 11)).foregroundStyle(Palette.dust)
                }
            }
            VStack(spacing: 10) { ForEach(windows) { QuotaRow(window: $0) } }
            if let warmup = runtime.warmups[account.id], warmup.needsAttention {
                Label("Auto warm-up: " + warmup.message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(Palette.ember).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                facts
                Spacer(minLength: 0)
                Button { withAnimation(.spring(duration: 0.34, bounce: 0.12)) { details.toggle() } } label: {
                    HStack(spacing: 3) {
                        Text(details ? "Less" : "More")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(details ? 180 : 0))
                    }.font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.dust).contentShape(Rectangle())
                }.buttonStyle(PressableStyle()).accessibilityLabel("Details for \(account.name)")
            }.font(.system(size: 11))
            if details {
                VStack(alignment: .leading, spacing: 14) {
                    if account.command.state != nil {
                        Text(account.command.state == "unknown" ? "Outcome unknown; open the warning to acknowledge." : "Redeeming…").font(.system(size: 11.5))
                    }
                    AccountDetails(account: account)
                    if account.provider == "anthropic" || account.provider == "xai", let extra = account.groups.extraUsage.data, extra.presentation == "bounded" {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(account.provider == "xai" ? "PAYG" : "Extra usage").font(.system(size: 12, weight: .semibold))
                            TallyMeter(percent: extra.remainingPercent)
                            Text("\(money(extra.used)) used of \(money(extra.limit))").font(.system(size: 11)).foregroundStyle(Palette.dust)
                        }
                    }
                    if account.provider == "openai" { OpenAICreditDetails(account: account, runtime: runtime) }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10))
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -6)).combined(with: .scale(scale: 0.98, anchor: .top)),
                                        removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))))
            }
        }.padding(14)
    }

    @ViewBuilder private var facts: some View {
        let groups = account.groups
        if account.provider == "anthropic" || account.provider == "xai" {
            fact(account.provider == "xai" ? "PAYG" : "Extra", extraLabel(groups.extraUsage.data) + (groups.extraUsage.stale ? " (out of date)" : ""))
        }
        if account.provider == "openai" {
            fact("Credits", groups.balances.data?.items.map { balance in
                balance.unlimited == true ? "Unlimited" : "\(balance.quantity ?? "Unknown")\(balance.referenceValue.map { " (\($0.currency) \($0.amount))" } ?? "")"
            }.joined(separator: ", ") ?? "Unavailable")
            fact("Resets", groups.resetSummary.data?.availableCount.map(String.init) ?? "?")
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        (Text(label + " ").foregroundStyle(Palette.dust) + Text(value)).lineLimit(1)
    }

    @ViewBuilder private var resetNotes: some View {
        if let operation = runtime.resetOperations[account.id], operation.state != .pending,
           !operation.acknowledgementRequired || resetExplanation {
            VStack(alignment: .leading, spacing: 8) {
                Text(operation.displayMessage(for: account)).fixedSize(horizontal: false, vertical: true)
                if operation.acknowledgementRequired {
                    Button("Acknowledge") { Task { await runtime.acknowledgeReset(account) } }
                        .buttonStyle(QuietButtonStyle()).disabled(runtime.resetBusy.contains(account.id))
                }
            }
            .font(.system(size: 11.5)).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
            .accessibilityElement(children: .contain)
        } else if resetExplanation && account.command.acknowledgementRequired {
            Text("Outcome unknown. Reading the existing operation before acknowledgement.").font(.system(size: 11.5))
        }
        if let error = runtime.resetErrors[account.id] { Text(error).font(.system(size: 11.5)).foregroundStyle(Palette.ember) }
    }

    private func money(_ money: Money?) -> String { money.map { "\($0.currency) \($0.amount)" } ?? "Unavailable" }
    private func extraLabel(_ extra: ExtraUsage?) -> String {
        switch extra?.presentation {
        case "off": "Off"
        case "used_only": "\(money(extra?.used)) used"
        case "bounded": "\(money(extra?.remaining)) left"
        default: "Unavailable"
        }
    }
}

struct ActiveLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 5))
            configuration.title
        }
        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.active)
        .padding(.horizontal, 8).frame(height: 20).background(Palette.active.opacity(0.13), in: Capsule())
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
            let size = NSSize(width: 560, height: 640)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Tally Settings"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 480, height: 420)
            window.contentViewController = NSHostingController(rootView: TallySettings(runtime: runtime))
            window.setContentSize(size)
            window.center()
            settingsWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func layoutPins() {
        let size = pins.fittingSize
        guard size.width != item.length else { return }
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
        runtime.dashboardVisible = true
        runtime.dashboardScrollPosition.scrollTo(edge: .top)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.popover.close()
        }
    }
    func popoverDidClose(_ notification: Notification) {
        runtime.dashboardVisible = false
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
