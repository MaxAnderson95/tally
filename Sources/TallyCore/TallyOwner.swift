import Foundation

public actor TallyOwner {
    private var inventorySource: @Sendable () throws -> InventoryRead
    private var identifySource: (@Sendable () throws -> String)?
    private let collections: @Sendable (StoredCredential) -> [CollectionJob]
    private var scanActivity: @Sendable (Date) async throws -> ActivityScan
    private let timezone: @Sendable () -> TimeZone
    private let clock: @Sendable () -> Date
    private let appBuild: String
    private var databaseIdentity: String?
    private var store: AccountIdentityStore
    private var storageError: Fault?
    private var inventory = Group<Inventory>()
    private var credentials: [String: StoredCredential] = [:]
    private var accounts: [Account] = []
    private struct JobKey: Hashable { var account: String; var job: String }
    private var tasks: [JobKey: Task<Void, Never>] = [:]
    private var attempts: [String: [String: AttemptPolicy]] = [:]
    private var activityViews: [String: Group<ActivityData>] = [:]
    private var activity = Group<ActivityData>()
    private var activityTask: Task<Void, Never>?
    private var nextInventoryAt: Date?
    private var stopping = false

    public init(databasePath: String, appBuild: String, storageURL: URL? = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tally/accounts.json")) {
        let source = OpenCodeInventory(path: databasePath)
        inventorySource = { try source.read() }
        identifySource = { try source.databaseIdentity() }
        store = AccountIdentityStore(url: storageURL)
        let usage = GoUsage()
        let anthropic = AnthropicUsage()
        let openai = OpenAIUsage()
        let grok = GrokUsage()
        collections = { credential in
            switch credential.provider {
            case "opencode-go": [.go { try await usage.collect(key: credential.key) }]
            case "anthropic": [anthropic.job(access: credential.key), anthropic.planJob(access: credential.key)]
            case "openai": openai.jobs(access: credential.key, workspace: credential.workspace)
            case "xai": grok.jobs(access: credential.key)
            default: []
            }
        }
        scanActivity = { cutoff in try await Task.detached { try OpenCodeActivity(path: databasePath).read(cutoff: cutoff) }.value }
        timezone = { TimeZone.current }
        clock = { Date() }
        self.appBuild = appBuild
    }

    init(appBuild: String = "test", clock: @escaping @Sendable () -> Date,
         storageURL: URL? = nil,
         inventory: @escaping @Sendable () throws -> InventoryRead,
         collections: (@Sendable (StoredCredential) -> [CollectionJob])? = nil,
         timezone: @escaping @Sendable () -> TimeZone = { TimeZone.current },
         scanActivity: @escaping @Sendable (Date) async throws -> ActivityScan = { _ in throw Fault("not_implemented", "No test activity source configured.") },
         collect: @escaping @Sendable (String) async throws -> GoObservation) {
        self.appBuild = appBuild; self.clock = clock; inventorySource = inventory
        self.collections = collections ?? { credential in
            credential.provider == "opencode-go" ? [.go { try await collect(credential.key) }] : []
        }
        self.scanActivity = scanActivity
        self.timezone = timezone
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
            if account.provider == "openai" { account.groups.selectResetSummary() }
            if var quotas = account.groups.quotas.data {
                for index in quotas.windows.indices {
                    quotas.windows[index].derive(at: now, groupStale: account.groups.quotas.stale)
                }
                account.groups.quotas.data = quotas
            }
            account.derivePresentation()
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
        scanActivity = { cutoff in try await Task.detached { try OpenCodeActivity(path: path).read(cutoff: cutoff) }.value }
        if (try? source.databaseIdentity()) != databaseIdentity { leaveNamespace() }
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
            namespace.records[index].attempts = attempts[namespace.records[index].account.id]
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
        activityTask?.cancel(); activityTask = nil; activity = Group(); activityViews = [:]
        tasks = [:]; attempts = [:]; accounts = []; credentials = [:]; inventory = Group(); databaseIdentity = nil
        nextInventoryAt = nil
    }

    private func enterNamespace(_ identity: String) {
        guard databaseIdentity != identity else { return }
        leaveNamespace()
        databaseIdentity = identity
        if var namespace = store.state.namespaces[identity] {
            for index in namespace.records.indices { namespace.records[index].account.groups.restoreStale() }
            store.state.namespaces[identity] = namespace
            accounts = namespace.records.filter(\.present).map(\.account)
            attempts = Dictionary(namespace.records.filter(\.present).map { ($0.account.id, $0.attempts ?? [:]) }, uniquingKeysWith: { _, latest in latest })
            inventory.data = Inventory(count: accounts.count, namespaceId: namespace.id)
            inventory.observedAt = namespace.observedAt
        } else { store.state.namespaces[identity] = InventoryNamespace() }
        activityViews = store.state.namespaces[identity]?.activity ?? [:]
        for key in activityViews.keys { activityViews[key]?.stale = true; activityViews[key]?.refreshing = false }
        activity = activityViews[ActivityRange.today.rawValue] ?? Group()
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
            if let previous = credentials[account.id], previous.fingerprint != credential.fingerprint {
                for key in tasks.keys where key.account == account.id { tasks[key]?.cancel(); tasks[key] = nil }
                account.groups.plan.refreshing = false
                account.groups.quotas.refreshing = false
                account.groups.extraUsage.refreshing = false
                account.groups.balances.refreshing = false
                account.groups.resetSummary.refreshing = false
                account.groups.resetDetails.refreshing = false
            }
            // Identity continuity does not make a newly rotated access token the rejected credential.
            for job in attempts[account.id, default: [:]].keys {
                if let blocked = attempts[account.id]?[job]?.blockedCredential, blocked != credential.fingerprint {
                    attempts[account.id]?[job]?.blockedCredential = nil
                }
            }
            nextAccounts.append(account); nextCredentials[account.id] = credential
        }
        for index in namespace.records.indices where nextCredentials[namespace.records[index].account.id] == nil {
            namespace.records[index].present = false
            namespace.records[index].account.groups = AccountGroups()
            namespace.records[index].account.pinned = false
            namespace.records[index].account.pinOrder = nil
            attempts[namespace.records[index].account.id] = nil
        }
        if !nextAccounts.isEmpty { namespace.initialized = true }
        namespace.observedAt = clock()
        for key in tasks.keys where nextCredentials[key.account] == nil { tasks[key]?.cancel(); tasks[key] = nil }
        accounts = nextAccounts; credentials = nextCredentials
        let pins = accounts.filter(\.pinned).sorted(by: accountOrder).map(\.id)
        for index in accounts.indices { accounts[index].pinOrder = pins.firstIndex(of: accounts[index].id) }
        store.state.namespaces[incoming.databaseIdentity] = namespace
        inventory.succeed(Inventory(count: accounts.count, namespaceId: namespace.id), at: clock())
        inventory.nextAttemptAt = clock().addingTimeInterval(120)
        nextInventoryAt = inventory.nextAttemptAt
        persist()
    }

    @discardableResult public func refresh(accountIDs: [String]? = nil) throws -> RefreshResponse {
        try refresh(accountIDs: accountIDs, automatic: false)
    }

    /// The app calls this while awake; the owner decides which work is due.
    public func tick() {
        guard !stopping else { return }
        if nextInventoryAt.map({ $0 <= clock() }) ?? true {
            _ = try? refresh(accountIDs: nil, automatic: true)
        } else {
            if inventory.error == nil {
                for account in accounts { _ = schedule(id: account.id, at: clock(), automatic: true) }
            }
            _ = scheduleActivity(at: clock(), automatic: true)
        }
    }

    public func wake() { _ = try? refresh(accountIDs: nil, automatic: false) }

    func activitySnapshot() -> Group<ActivityData> {
        activityResponse().activity
    }

    public func activityResponse(range: ActivityRange = .today) -> ActivityResponse {
        var value = activityViews[range.rawValue] ?? activity
        value.lastAttemptAt = activity.lastAttemptAt; value.refreshing = activity.refreshing
        value.nextAttemptAt = activity.nextAttemptAt; value.error = activity.error
        value.stale = value.stale || activity.stale
        value.age(at: clock())
        if let data = value.data, data.timezone != timezone().identifier {
            value.stale = true
            value.error = value.error ?? Fault("activity_timezone_changed", "Mac timezone changed; cached buckets remain in \(data.timezone) until a successful scan.")
        }
        if let data = value.data, let zone = TimeZone(identifier: data.timezone) {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            if data.trend.days.last?.startAt != calendar.startOfDay(for: clock()) {
                value.stale = true
                value.error = value.error ?? Fault("activity_calendar_changed", "A new calendar day is awaiting a scan; the last observed range is retained.")
            }
        }
        return ActivityResponse(status: snapshot().status, activity: value)
    }

    private func refresh(accountIDs: [String]?, automatic: Bool) throws -> RefreshResponse {
        guard !stopping else { throw Fault("shutting_down", "Tally is shutting down.") }
        if let accountIDs, !Set(accountIDs).isSubset(of: Set(accounts.map(\.id))) {
            throw Fault("account_not_found", "One or more Accounts were not found.")
        }
        let now = clock()
        inventory.lastAttemptAt = now
        do {
            if let identifySource { enterNamespace(try identifySource()) }
            reconcile(try inventorySource())
        } catch {
            let fault = error as? Fault ?? Fault("inventory_unavailable", "OpenCode inventory could not be read.")
            inventory.fail(fault, at: now)
            nextInventoryAt = now.addingTimeInterval(120)
            inventory.nextAttemptAt = nextInventoryAt
            for index in accounts.indices {
                accounts[index].groups.restoreStale()
                for group in ReadingGroup.allCases {
                    group.update(&accounts[index].groups, next: nil, fault: fault)
                }
            }
            _ = scheduleActivity(at: now, automatic: automatic)
            persist()
            throw fault
        }
        if let accountIDs, !Set(accountIDs).isSubset(of: Set(accounts.map(\.id))) { throw Fault("account_not_found", "Account identity changed during inventory refresh.") }
        let requested = accountIDs.map(Set.init)
        let schedules = accounts.filter { requested?.contains($0.id) ?? true }.map { account in
            AccountSchedule(accountId: account.id, schedule: schedule(id: account.id, at: now, automatic: automatic))
        }
        let activity = scheduleActivity(at: now, automatic: automatic)
        persist()
        return RefreshResponse(accounts: schedules, activity: activity)
    }

    private func schedule(id: String, at now: Date, automatic: Bool) -> Schedule {
        guard let index = accounts.firstIndex(where: { $0.id == id }), let credential = credentials[id] else {
            return Schedule(state: "blocked", reason: Fault("account_not_found", "Account no longer exists."))
        }
        let jobs = collections(credential)
        if credential.expiresAt.map({ $0 <= now }) == true {
            let fault = Fault("credentials_expired", "Waiting for OpenCode to supply a usable access token. Expiry alone does not require reauthentication.")
            var policy = attempts[id]?["credential"] ?? AttemptPolicy()
            let newlyBlocked = policy.blockedCredential != credential.fingerprint
            _ = policy.finish(at: now, fault: fault, credential: credential.fingerprint)
            attempts[id, default: [:]]["credential"] = policy
            for group in ReadingGroup.allCases { group.update(&accounts[index].groups, next: nil, fault: fault) }
            if newlyBlocked { persist() }
            return Schedule(state: "blocked", reason: fault)
        }
        guard !jobs.isEmpty else {
            return Schedule(state: "blocked", reason: Fault("not_implemented", "This provider's collector is not available in this slice."))
        }
        // A rejection applies to the credential across endpoints. Transient failures stay job-local.
        if attempts[id, default: [:]].values.contains(where: { $0.blockedCredential == credential.fingerprint }) {
            let fault = Fault("credentials_rejected", "Waiting for changed usable credentials from OpenCode.")
            for group in ReadingGroup.allCases { group.update(&accounts[index].groups, next: nil, fault: fault) }
            return Schedule(state: "blocked", reason: fault)
        }
        let schedules = jobs.map { job -> Schedule in
            let key = JobKey(account: id, job: job.id)
            if tasks[key] != nil { return Schedule(state: "joined") }
            var policy = attempts[id]?[job.id] ?? AttemptPolicy()
            if let decision = policy.decision(at: now, automatic: automatic) { return decision }
            policy.start(at: now)
            attempts[id, default: [:]][job.id] = policy
            for group in job.groups { group.update(&accounts[index].groups, attempt: now, next: nil, refreshing: true) }
            let namespace = databaseIdentity
            tasks[key] = Task {
                let result: Result<[GroupObservation], Error>
                do {
                    let observations = try await job.run()
                    guard Set(observations.map(\.group)) == Set(job.groups), observations.count == job.groups.count else {
                        throw Fault("provider_response_invalid", "Collection did not report every expected group.")
                    }
                    result = .success(observations)
                } catch { result = .failure(error) }
                finish(key: key, credential: credential.fingerprint, namespace: namespace, groups: job.groups, result: result)
            }
            persist()
            return Schedule(state: "started")
        }
        // The account summary reports active work first; every group retains its own deadline/error.
        for state in ["started", "joined", "deferred", "blocked"] {
            if let schedule = schedules.filter({ $0.state == state }).min(by: { ($0.nextAttemptAt ?? .distantFuture) < ($1.nextAttemptAt ?? .distantFuture) }) { return schedule }
        }
        return Schedule(state: "blocked")
    }

    private func scheduleActivity(at now: Date, automatic: Bool) -> Schedule {
        if activityTask != nil { return Schedule(state: "joined") }
        // Explicit refresh always requests a scan, independently of provider cooldowns.
        if automatic, let next = activity.nextAttemptAt, now < next {
            return Schedule(state: "deferred", nextAttemptAt: next)
        }
        activity.lastAttemptAt = now; activity.refreshing = true; activity.nextAttemptAt = nil
        let scan = scanActivity
        let namespace = databaseIdentity
        let zone = timezone()
        let namespaceID = namespace.flatMap { store.state.namespaces[$0]?.id }
        activityTask = Task {
            var fault: Fault?
            var views: [String: ActivityData]?
            do {
                let result = try await scan(now)
                guard result.databaseIdentity == namespace, let namespaceID else { throw Fault("activity_unavailable", "Activity source identity changed; refresh the inventory.") }
                views = await Task.detached { result.derive(namespace: namespaceID, cutoff: now, timezone: zone) }.value
            }
            catch { fault = error as? Fault ?? Fault("activity_unavailable", "Recorded activity could not be scanned.") }
            guard !Task.isCancelled, namespace == databaseIdentity else { return }
            if let fault { activity.fail(fault, at: now) }
            else if let views {
                activityViews = views.mapValues { data in
                    var group = Group<ActivityData>(); group.succeed(data, at: now); return group
                }
                activity = activityViews[ActivityRange.today.rawValue]!
                if let namespace { store.state.namespaces[namespace]?.activity = activityViews }
            }
            activity.nextAttemptAt = clock().addingTimeInterval(120)
            activityTask = nil
            persist()
        }
        return Schedule(state: "started")
    }

    private func finish(key: JobKey, credential: String, namespace: String?, groups: [ReadingGroup], result: Result<[GroupObservation], Error>) {
        guard !Task.isCancelled, namespace == databaseIdentity else { return }
        tasks[key] = nil
        guard credentials[key.account]?.fingerprint == credential, let index = accounts.firstIndex(where: { $0.id == key.account }) else { return }
        let now = clock()
        var policy = attempts[key.account]?[key.job] ?? AttemptPolicy()
        switch result {
        case .success(let observations):
            _ = policy.finish(at: now, fault: nil)
            for observation in observations { observation.apply(to: &accounts[index].groups, at: now) }
            for group in groups { group.update(&accounts[index].groups, next: policy.nextAttemptAt) }
        case .failure(let error):
            let fault = policy.finish(at: now, fault: error as? Fault ?? Fault("provider_unavailable", "Provider collection failed."), credential: credential)
            for group in groups { group.update(&accounts[index].groups, next: policy.nextAttemptAt, fault: fault) }
        }
        attempts[key.account, default: [:]][key.job] = policy
        if attempts[key.account, default: [:]].values.contains(where: { $0.blockedCredential == credential }) {
            for group in ReadingGroup.allCases {
                group.update(&accounts[index].groups, next: nil, fault: Fault("credentials_rejected", "Waiting for changed usable credentials from OpenCode."))
            }
        }
        if let fault = inventory.error {
            for group in ReadingGroup.allCases { group.update(&accounts[index].groups, next: nil, fault: fault) }
        }
        persist()
    }

    public func waitForCollection() async {
        for task in Array(tasks.values) { await task.value }
        await activityTask?.value
        persist()
    }
    public func shutdown() async {
        stopping = true
        for task in tasks.values { task.cancel() }
        activityTask?.cancel()
        await waitForCollection()
    }
}
