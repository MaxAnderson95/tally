import Foundation

public actor TallyOwner {
    private var inventorySource: @Sendable () throws -> InventoryRead
    private var identifySource: (@Sendable () throws -> String)?
    private let collect: @Sendable (String) async throws -> GoObservation
    private let clock: @Sendable () -> Date
    private let appBuild: String
    private var databaseIdentity: String?
    private var store: AccountIdentityStore
    private var storageError: Fault?
    private var inventory = Group<Inventory>()
    private var credentials: [String: StoredCredential] = [:]
    private var accounts: [Account] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var stopping = false

    public init(databasePath: String, appBuild: String, storageURL: URL? = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tally/accounts.json")) {
        let source = OpenCodeInventory(path: databasePath)
        inventorySource = { try source.read() }
        identifySource = { try source.databaseIdentity() }
        store = AccountIdentityStore(url: storageURL)
        let usage = GoUsage()
        collect = { try await usage.collect(key: $0) }
        clock = { Date() }
        self.appBuild = appBuild
    }

    init(appBuild: String = "test", clock: @escaping @Sendable () -> Date,
         storageURL: URL? = nil,
         inventory: @escaping @Sendable () throws -> InventoryRead,
         collect: @escaping @Sendable (String) async throws -> GoObservation) {
        self.appBuild = appBuild; self.clock = clock; inventorySource = inventory; self.collect = collect
        store = AccountIdentityStore(url: storageURL)
    }

    public func snapshot() -> AccountsResponse {
        let now = clock()
        var inventory = inventory; inventory.age(at: now)
        let display = accounts.map { original in
            var account = original
            account.groups.plan.age(at: now); account.groups.quotas.age(at: now)
            account.groups.extraUsage.age(at: now); account.groups.balances.age(at: now)
            account.groups.resetSummary.age(at: now); account.groups.resetDetails.age(at: now)
            if var quotas = account.groups.quotas.data {
                for index in quotas.windows.indices {
                    quotas.windows[index].derive(at: now, groupStale: account.groups.quotas.stale)
                }
                account.groups.quotas.data = quotas
                account.pin.lines = quotas.windows.filter { $0.durationSeconds != nil }.prefix(2).map {
                    PinLine(windowId: $0.id, label: $0.label, remainingPercent: $0.remainingPercent, stale: $0.stale)
                }
                account.pin.warning = account.pin.lines.contains { $0.stale }
            }
            return account
        }
        return AccountsResponse(status: Status(appBuild: appBuild, serverTime: now, timezone: TimeZone.current.identifier,
                                               owner: stopping ? "shutting_down" : "ready", inventory: inventory), accounts: display.sorted(by: accountOrder))
    }

    public func account(id: String) throws -> AccountResponse {
        let current = snapshot()
        guard let account = current.accounts.first(where: { $0.id == id }) else {
            throw Fault("account_not_found", "Account not found.")
        }
        return AccountResponse(status: current.status, account: account)
    }

    public func settingsError() -> Fault? { storageError }

    public func setDatabasePath(_ path: String) throws {
        let source = OpenCodeInventory(path: path)
        inventorySource = { try source.read() }
        identifySource = { try source.databaseIdentity() }
        leaveNamespace()
        try refresh(accountIDs: [])
    }

    public func setPins(_ orderedIDs: [String]) throws {
        guard Set(orderedIDs).count == orderedIDs.count, Set(orderedIDs).isSubset(of: Set(accounts.map(\.id))) else {
            throw Fault("invalid_request", "Choose each current Account at most once.")
        }
        let previous = accounts
        for index in accounts.indices {
            accounts[index].pinOrder = orderedIDs.firstIndex(of: accounts[index].id)
            accounts[index].pinned = accounts[index].pinOrder != nil
        }
        cacheAccounts()
        do { try store.save(); storageError = nil }
        catch { accounts = previous; cacheAccounts(); throw error }
    }

    public func identityEvidence(accountID: String) throws -> IdentityEvidence {
        guard inventory.error == nil, let evidence = credentials[accountID]?.evidence else {
            throw Fault("inventory_unavailable", "Current Account identity is unavailable.")
        }
        return evidence
    }

    private func cacheAccounts() {
        guard let databaseIdentity, var namespace = store.state.namespaces[databaseIdentity] else { return }
        for index in namespace.records.indices {
            if let account = accounts.first(where: { $0.id == namespace.records[index].account.id }) { namespace.records[index].account = account }
        }
        store.state.namespaces[databaseIdentity] = namespace
    }

    private func persist() {
        cacheAccounts()
        do { try store.save(); storageError = nil }
        catch { storageError = error as? Fault }
    }

    private func leaveNamespace() {
        persist()
        for task in tasks.values { task.cancel() }
        tasks = [:]; accounts = []; credentials = [:]; inventory = Group(); databaseIdentity = nil
    }

    private func enterNamespace(_ identity: String) {
        guard databaseIdentity != identity else { return }
        leaveNamespace()
        databaseIdentity = identity
        if var namespace = store.state.namespaces[identity] {
            for index in namespace.records.indices { namespace.records[index].account.groups.restoreStale() }
            store.state.namespaces[identity] = namespace
            accounts = namespace.records.filter(\.present).map(\.account)
            inventory.data = Inventory(count: accounts.count, namespaceId: namespace.id)
            inventory.observedAt = namespace.observedAt
        } else { store.state.namespaces[identity] = InventoryNamespace() }
    }

    private func reconcile(_ incoming: InventoryRead) {
        enterNamespace(incoming.databaseIdentity)
        cacheAccounts()
        var namespace = store.state.namespaces[incoming.databaseIdentity]!
        var nextAccounts: [Account] = []
        var nextCredentials: [String: StoredCredential] = [:]
        let sorted = incoming.credentials.sorted {
            if $0.provider != $1.provider { return providerOrder.firstIndex(of: $0.provider)! < providerOrder.firstIndex(of: $1.provider)! }
            if $0.name.lowercased() != $1.name.lowercased() { return $0.name.lowercased() < $1.name.lowercased() }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.storedID < $1.storedID
        }
        for credential in sorted {
            let existing = namespace.records.firstIndex { $0.evidence.relation(to: credential.evidence) == .same }
            var account: Account
            if let existing {
                account = namespace.records[existing].account
                namespace.records[existing].evidence = credential.evidence
                namespace.records[existing].present = true
            } else {
                let color = namespace.nextColors[credential.provider, default: 0]
                account = Account(id: UUID().uuidString, provider: credential.provider, service: providerServices[credential.provider]!, name: credential.name,
                                  pinned: !namespace.initialized, pinOrder: namespace.initialized ? nil : nextAccounts.count, identityColorIndex: color % 6)
                namespace.nextColors[credential.provider] = color + 1
                namespace.records.append(IdentityRecord(evidence: credential.evidence, account: account, present: true))
            }
            account.name = credential.name
            nextAccounts.append(account); nextCredentials[account.id] = credential
        }
        for index in namespace.records.indices where nextCredentials[namespace.records[index].account.id] == nil {
            namespace.records[index].present = false
            namespace.records[index].account.groups = AccountGroups()
            namespace.records[index].account.pinned = false
            namespace.records[index].account.pinOrder = nil
        }
        if !nextAccounts.isEmpty { namespace.initialized = true }
        namespace.observedAt = clock()
        for id in credentials.keys where nextCredentials[id] == nil { tasks[id]?.cancel(); tasks[id] = nil }
        accounts = nextAccounts; credentials = nextCredentials
        let pins = accounts.filter(\.pinned).sorted(by: accountOrder).map(\.id)
        for index in accounts.indices { accounts[index].pinOrder = pins.firstIndex(of: accounts[index].id) }
        store.state.namespaces[incoming.databaseIdentity] = namespace
        inventory.succeed(Inventory(count: accounts.count, namespaceId: namespace.id), at: clock())
        persist()
    }

    @discardableResult public func refresh(accountIDs: [String]? = nil) throws -> RefreshResponse {
        guard !stopping else { throw Fault("shutting_down", "Tally is shutting down.") }
        if let accountIDs, !Set(accountIDs).isSubset(of: Set(accounts.map(\.id))) {
            throw Fault("account_not_found", "One or more Accounts were not found.")
        }
        let now = clock()
        do {
            if let identifySource { enterNamespace(try identifySource()) }
            reconcile(try inventorySource())
        } catch {
            let fault = error as? Fault ?? Fault("inventory_unavailable", "OpenCode inventory could not be read.")
            inventory.fail(fault, at: now)
            for index in accounts.indices {
                accounts[index].groups.restoreStale()
                accounts[index].groups.plan.fail(fault, at: now)
                accounts[index].groups.quotas.fail(fault, at: now)
            }
            throw fault
        }
        if let accountIDs, !Set(accountIDs).isSubset(of: Set(accounts.map(\.id))) { throw Fault("account_not_found", "Account identity changed during inventory refresh.") }
        let requested = accountIDs.map(Set.init)
        let schedules = accounts.filter { requested?.contains($0.id) ?? true }.map { account in
            AccountSchedule(accountId: account.id, schedule: schedule(id: account.id, at: now))
        }
        return RefreshResponse(accounts: schedules, activity: Schedule(state: "blocked", reason: Fault("not_implemented", "Recorded activity is not available in this slice.")))
    }

    private func schedule(id: String, at now: Date) -> Schedule {
        if tasks[id] != nil { return Schedule(state: "joined") }
        guard let index = accounts.firstIndex(where: { $0.id == id }), let credential = credentials[id] else {
            return Schedule(state: "blocked", reason: Fault("account_not_found", "Account no longer exists."))
        }
        guard credential.provider == "opencode-go" else {
            return Schedule(state: "blocked", reason: Fault("not_implemented", "This provider's collector is not available in this slice."))
        }
        if let attempt = accounts[index].groups.quotas.lastAttemptAt, now.timeIntervalSince(attempt) < 15 {
            return Schedule(state: "deferred", nextAttemptAt: attempt.addingTimeInterval(15))
        }
        accounts[index].groups.plan.refreshing = true
        accounts[index].groups.quotas.refreshing = true
        accounts[index].groups.plan.lastAttemptAt = now
        accounts[index].groups.quotas.lastAttemptAt = now
        let collect = self.collect
        let namespace = databaseIdentity
        tasks[id] = Task {
            let result: Result<GoObservation, Error>
            do { result = .success(try await collect(credential.key)) } catch { result = .failure(error) }
            finish(id: id, key: credential.key, namespace: namespace, result: result)
        }
        return Schedule(state: "started")
    }

    private func finish(id: String, key: String, namespace: String?, result: Result<GoObservation, Error>) {
        guard !Task.isCancelled, namespace == databaseIdentity else { return }
        tasks[id] = nil
        guard credentials[id]?.key == key, let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let now = clock()
        switch result {
        case .success(let observation):
            accounts[index].groups.plan.succeed(Plan(name: "Go"), at: now)
            accounts[index].groups.quotas.succeed(Quotas(windows: observation.windows), at: now)
            accounts[index].groups.extraUsage.succeed(nil, at: now)
            accounts[index].groups.balances.succeed(nil, at: now)
            accounts[index].groups.resetSummary.succeed(nil, at: now)
            accounts[index].groups.resetDetails.succeed(nil, at: now)
        case .failure(let error):
            let fault = error as? Fault ?? Fault("provider_unavailable", "OpenCode Go collection failed.")
            accounts[index].groups.plan.fail(fault, at: now)
            accounts[index].groups.quotas.fail(fault, at: now)
        }
        if inventory.error != nil { accounts[index].groups.restoreStale() }
        persist()
    }

    public func waitForCollection() async { for task in Array(tasks.values) { await task.value }; persist() }
    public func shutdown() async {
        stopping = true
        for task in tasks.values { task.cancel() }
        await waitForCollection()
    }
}
