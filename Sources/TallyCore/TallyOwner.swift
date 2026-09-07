import Foundation

public actor TallyOwner {
    private let inventorySource: @Sendable () throws -> [GoCredential]
    private let collect: @Sendable (String) async throws -> GoObservation
    private let clock: @Sendable () -> Date
    private let appBuild: String
    private let namespaceID = UUID().uuidString
    private var inventory = Group<Inventory>()
    private var credentials: [String: GoCredential] = [:]
    private var accounts: [Account] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var stopping = false

    public init(databasePath: String, appBuild: String) {
        let source = OpenCodeInventory(path: databasePath)
        inventorySource = { try source.read() }
        collect = { try await GoUsage().collect(key: $0) }
        clock = { Date() }
        self.appBuild = appBuild
    }

    init(appBuild: String = "test", clock: @escaping @Sendable () -> Date,
         inventory: @escaping @Sendable () throws -> [GoCredential],
         collect: @escaping @Sendable (String) async throws -> GoObservation) {
        self.appBuild = appBuild; self.clock = clock; inventorySource = inventory; self.collect = collect
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
                                               owner: stopping ? "shutting_down" : "ready", inventory: inventory), accounts: display)
    }

    public func account(id: String) throws -> AccountResponse {
        let current = snapshot()
        guard let account = current.accounts.first(where: { $0.id == id }) else {
            throw Fault("account_not_found", "Account not found.")
        }
        return AccountResponse(status: current.status, account: account)
    }

    @discardableResult public func refresh(accountIDs: [String]? = nil) throws -> RefreshResponse {
        guard !stopping else { throw Fault("shutting_down", "Tally is shutting down.") }
        if let accountIDs, !Set(accountIDs).isSubset(of: Set(accounts.map(\.id))) {
            throw Fault("account_not_found", "One or more Accounts were not found.")
        }
        let now = clock()
        do {
            let incoming = try inventorySource()
            var nextAccounts: [Account] = []
            var nextCredentials: [String: GoCredential] = [:]
            for credential in incoming {
                // Key equality establishes Go continuity only inside this process and database selection.
                let existing = accounts.first { credentials[$0.id]?.key == credential.key }
                var account = existing ?? Account(id: UUID().uuidString, name: credential.name)
                account.name = credential.name
                nextAccounts.append(account); nextCredentials[account.id] = credential
            }
            nextAccounts.sort {
                let lhs = $0.name.lowercased(), rhs = $1.name.lowercased()
                if lhs != rhs { return lhs < rhs }
                if $0.name != $1.name { return $0.name < $1.name }
                return (nextCredentials[$0.id]?.storedID ?? "") < (nextCredentials[$1.id]?.storedID ?? "")
            }
            for index in nextAccounts.indices { nextAccounts[index].pinOrder = index }
            for id in credentials.keys where nextCredentials[id] == nil { tasks[id]?.cancel(); tasks[id] = nil }
            accounts = nextAccounts; credentials = nextCredentials
            inventory.succeed(Inventory(count: accounts.count, namespaceId: namespaceID), at: now)
        } catch {
            let fault = error as? Fault ?? Fault("inventory_unavailable", "OpenCode inventory could not be read.")
            inventory.fail(fault, at: now)
            for index in accounts.indices {
                accounts[index].groups.plan.fail(fault, at: now)
                accounts[index].groups.quotas.fail(fault, at: now)
            }
            throw fault
        }
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
        if let attempt = accounts[index].groups.quotas.lastAttemptAt, now.timeIntervalSince(attempt) < 15 {
            return Schedule(state: "deferred", nextAttemptAt: attempt.addingTimeInterval(15))
        }
        accounts[index].groups.plan.refreshing = true
        accounts[index].groups.quotas.refreshing = true
        accounts[index].groups.plan.lastAttemptAt = now
        accounts[index].groups.quotas.lastAttemptAt = now
        let collect = self.collect
        tasks[id] = Task {
            let result: Result<GoObservation, Error>
            do { result = .success(try await collect(credential.key)) } catch { result = .failure(error) }
            finish(id: id, key: credential.key, result: result)
        }
        return Schedule(state: "started")
    }

    private func finish(id: String, key: String, result: Result<GoObservation, Error>) {
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
    }

    public func waitForCollection() async { for task in Array(tasks.values) { await task.value } }
    public func shutdown() async {
        stopping = true
        for task in tasks.values { task.cancel() }
        await waitForCollection()
    }
}
