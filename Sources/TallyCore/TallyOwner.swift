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
    private var redemptions: RedemptionJournal
    private let resetProvider: OpenAIRedemption
    private var redemptionTasks: [String: Task<Void, Never>] = [:]
    private let quitWait: Duration

    public init(databasePath: String, appBuild: String, storageURL: URL? = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tally/accounts.json")) {
        let source = OpenCodeInventory(path: databasePath)
        inventorySource = { try source.read() }
        identifySource = { try source.databaseIdentity() }
        store = AccountIdentityStore(url: storageURL)
        let usage = GoUsage()
        let anthropic = AnthropicUsage()
        let openai = OpenAIUsage()
        let grok = GrokUsage()
        redemptions = RedemptionJournal(storage: storageURL.map { .disk($0.deletingLastPathComponent().appendingPathComponent("redemptions.sqlite")) } ?? .unavailable, now: Date())
        resetProvider = OpenAIRedemption()
        quitWait = .seconds(15)
        collections = { credential in
            switch credential.provider {
            case "opencode-go": [.go { try await usage.collect(key: credential.key) }]
            case "anthropic": [anthropic.job(access: credential.key), anthropic.planJob(access: credential.key)]
            case "openai": openai.jobs(access: credential.key, workspace: credential.workspace)
            case "xai": grok.jobs(access: credential.key)
            default: []
            }
        }
        scanActivity = { cutoff in try await OpenCodeActivity(path: databasePath).scan(cutoff: cutoff) }
        timezone = { TimeZone.current }
        clock = { Date() }
        self.appBuild = appBuild
    }

    init(appBuild: String = "test", clock: @escaping @Sendable () -> Date,
         storageURL: URL? = nil,
         redemptionStorage: RedemptionStorage = .unavailable,
         resetProvider: OpenAIRedemption = OpenAIRedemption(transport: { _ in throw Fault("unexpected", "No test reset transport configured.") }),
         quitWait: Duration = .seconds(15),
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
        redemptions = RedemptionJournal(storage: redemptionStorage, now: clock())
        self.resetProvider = resetProvider
        self.quitWait = quitWait
    }

    public func snapshot() -> AccountsResponse {
        let now = clock()
        var inventory = inventory; inventory.age(at: now)
        let display = accounts.map { original in
            var account = original
            if let block = redemptions.block(accountID: account.id, target: credentials[account.id]?.evidence) {
                account.command = CommandSummary(blockingOperationId: block.result.operationId, state: block.result.state.rawValue,
                                                 acknowledgementRequired: block.result.acknowledgementRequired)
            } else { account.command = CommandSummary() }
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
                                               owner: stopping ? "shutting_down" : "ready", inventory: inventory,
                                               recoveryStorage: RecoveryStorage(available: redemptions.error == nil, error: redemptions.error)), accounts: display.sorted(by: accountOrder))
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
        scanActivity = { cutoff in try await OpenCodeActivity(path: path).scan(cutoff: cutoff) }
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

    public func setIdentityColor(accountID: String, index: Int) throws {
        guard (0..<6).contains(index) else { throw Fault("invalid_request", "Choose one of the six Account colors.") }
        guard let position = accounts.firstIndex(where: { $0.id == accountID }) else {
            throw Fault("account_not_found", "Account not found.")
        }
        let previous = accounts[position].identityColorIndex
        accounts[position].identityColorIndex = index
        cacheAccounts()
        do { try store.save(); storageError = nil }
        catch { accounts[position].identityColorIndex = previous; cacheAccounts(); throw error }
    }

    public func identityEvidence(accountID: String) throws -> IdentityEvidence {
        guard inventory.error == nil, let evidence = credentials[accountID]?.evidence else {
            throw Fault("inventory_unavailable", "Current Account identity is unavailable.")
        }
        return evidence
    }

    private func cacheAccounts() {
        guard let databaseIdentity, var namespace = store.state.namespaces[databaseIdentity] else { return }
        if namespace.colorsByCredential == nil { namespace.colorsByCredential = [:] }
        for account in accounts {
            if let credential = credentials[account.id] {
                namespace.colorsByCredential?[credential.colorPreferenceKey] = account.identityColorIndex
            }
        }
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
            // Cosmetic preferences follow the OpenCode row, independently of credential identity.
            account.identityColorIndex = namespace.colorsByCredential?[credential.colorPreferenceKey] ?? account.identityColorIndex
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
        redemptions.retryResults()
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
        if let data = value.data, data.pricing.revision != ActivityPricing().revision || data.pricing.digest != ActivityPricing().digest {
            value.stale = true
            value.error = value.error ?? Fault("activity_pricing_changed", "Reviewed pricing changed; cached estimates retain revision \(data.pricing.revision) until a successful scan.")
        }
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
            if job.id == "reset-credits", redemptionTasks.keys.contains(where: { redemptions.records[$0]?.result.accountId == id }) { return Schedule(state: "joined") }
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
                guard ActivityPrices.bundled != nil else { throw Fault("activity_pricing_unavailable", "Reviewed pricing resource failed verification; reinstall this Tally build. Cached estimates retain their original revision.") }
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
        let deadline = ContinuousClock.now.advanced(by: quitWait)
        while !redemptionTasks.isEmpty && ContinuousClock.now < deadline {
            do { try await Task.sleep(until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(10))), clock: .continuous) }
            catch { break }
        }
        for task in redemptionTasks.values { task.cancel() }
        // Durable pending/marker records already encode the recovery decision. Do not extend
        // the Quit deadline waiting for cancellation, another disk write, or collection.
        redemptions.interruptPending(at: clock())
        redemptionTasks = [:]
    }

    public func submitRedemption(accountID: String, operationID: String, creditID: String? = nil) throws -> Redemption {
        let id = try operationUUID(operationID)
        guard creditID.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true else {
            throw Fault("invalid_request", "creditId must be a nonempty credit ID.")
        }
        if let existing = redemptions.records[id] {
            guard existing.result.accountId == accountID, existing.result.requestedCreditId == creditID else {
                throw Fault("operation_conflict", "This UUID already identifies a different original request.")
            }
            return existing.result
        }
        guard !stopping else { throw Fault("shutting_down", "Tally is shutting down.") }
        guard let account = accounts.first(where: { $0.id == accountID }) else { throw Fault("account_not_found", "Account not found.") }
        guard account.provider == "openai" else { throw Fault("invalid_request", "Banked resets require an OpenAI Account.") }
        guard let target = credentials[accountID]?.evidence, let namespace = databaseIdentity else {
            throw Fault("inventory_unavailable", "Current Account identity is unavailable.")
        }
        if let blocked = redemptions.block(accountID: accountID, target: target) {
            var fault = Fault("account_blocked", "A pending or unacknowledged operation blocks this Account or its uncertain upstream identity.")
            fault.blockingOperationId = blocked.result.operationId
            throw fault
        }
        let now = clock()
        let result = Redemption(operationId: id, accountId: accountID, accountName: account.name, requestedCreditId: creditID,
                                createdAt: now, updatedAt: now, resultUrl: "/api/v1/redemptions/\(id)")
        let record = RedemptionRecord(result: result, namespace: namespace, target: target)
        do { try redemptions.save(record) }
        catch { redemptions.retainUncommitted(record, at: now); throw recoveryFault() }
        // Unstructured owner work survives the submitting browser's task cancellation.
        redemptionTasks[id] = Task { await performRedemption(id) }
        return result
    }

    public func redemption(operationID: String) throws -> Redemption {
        guard let result = redemptions.records[try operationUUID(operationID)]?.result else { throw Fault("operation_not_found", "Operation not found.") }
        return result
    }

    public func acknowledgeRedemption(operationID: String) throws -> Redemption {
        let id = try operationUUID(operationID)
        guard var record = redemptions.records[id] else { throw Fault("operation_not_found", "Operation not found.") }
        guard record.result.state == .unknown else { throw Fault("operation_conflict", "Only an unknown outcome can be acknowledged.") }
        if record.result.acknowledgedAt != nil { return record.result }
        guard !stopping else { throw Fault("shutting_down", "Tally is shutting down.") }
        record.result.acknowledgedAt = clock(); record.result.updatedAt = clock()
        record.result.acknowledgementRequired = false
        try redemptions.save(record)
        return record.result
    }

    private func currentRedemptionCredential(_ record: RedemptionRecord) throws -> StoredCredential {
        inventory.lastAttemptAt = clock()
        do {
            if let identifySource { enterNamespace(try identifySource()) }
            reconcile(try inventorySource())
        } catch {
            let fault = Fault("inventory_unavailable", "Current OpenCode inventory could not be verified.")
            inventory.fail(fault, at: clock())
            nextInventoryAt = clock().addingTimeInterval(120)
            inventory.nextAttemptAt = nextInventoryAt
            for index in accounts.indices {
                accounts[index].groups.restoreStale()
                for group in ReadingGroup.allCases { group.update(&accounts[index].groups, next: nil, fault: fault) }
            }
            persist()
            throw fault
        }
        guard record.namespace == databaseIdentity, let credential = credentials[record.result.accountId],
              record.target.relation(to: credential.evidence) == .same else {
            throw Fault("credentials_unavailable", "The original Account target is no longer verified. No substitute Account will be used.")
        }
        guard credential.expiresAt.map({ $0 > clock() }) ?? true, !credential.key.isEmpty,
              credential.workspace.map({ !$0.isEmpty }) == true,
              !attempts[record.result.accountId, default: [:]].values.contains(where: { $0.blockedCredential == credential.fingerprint }) else {
            throw Fault("credentials_unavailable", "Waiting for OpenCode to supply usable credentials and workspace for this Account.")
        }
        return credential
    }

    private func performRedemption(_ id: String) async {
        guard var record = redemptions.records[id] else { return }
        let accountID = record.result.accountId
        var preflightStarted = false
        var preflightFinished = false
        var consumeAttempted = false
        var credential: StoredCredential?
        do {
            try Task.checkCancellation()
            let key = JobKey(account: accountID, job: "reset-credits")
            // Join an existing read, then verify its resulting backoff and current identity.
            await tasks[key]?.value
            try Task.checkCancellation()
            guard redemptions.records[id]?.result.state == .pending else { return }
            let current = try currentRedemptionCredential(record)
            credential = current
            var policy = attempts[accountID]?[key.job] ?? AttemptPolicy()
            if let deadline = policy.cooldownUntil, deadline > clock() {
                var fault = Fault("provider_cooldown", "Credit preflight is deferred. This command will not queue a later spend.")
                fault.retryAt = deadline
                throw fault
            }
            policy.start(at: clock()); attempts[accountID, default: [:]][key.job] = policy
            preflightStarted = true
            if let index = accounts.firstIndex(where: { $0.id == accountID }) {
                ReadingGroup.resetDetails.update(&accounts[index].groups, attempt: clock(), next: nil, refreshing: true)
            }
            persist()
            let details = try await resetProvider.credits(current)
            try Task.checkCancellation()
            guard redemptions.records[id]?.result.state == .pending else { return }
            // Re-read after the network suspension: removal, namespace switch, or credential rotation cannot retarget the command.
            let verified = try currentRedemptionCredential(record)
            guard verified.fingerprint == current.fingerprint else { throw Fault("credentials_unavailable", "Credentials changed during preflight. Request a new operation using current details.") }
            finish(key: key, credential: current.fingerprint, namespace: record.namespace, groups: [.resetDetails], result: .success([.resetDetails(details)]))
            preflightFinished = true
            guard let selected = selectCredit(details, requested: record.result.requestedCreditId, at: clock()) else {
                record.result.state = .no_credit
                record.result.error = Fault("no_credit", "Preflight found no identifiable available credit matching the request.")
                completeRedemption(record)
                return
            }
            record.result.selectedCreditId = selected.id
            record.result.updatedAt = clock()
            record.maySend = true
            try redemptions.save(record)
            consumeAttempted = true
            let verdict = try await resetProvider.consume(verified, credit: selected.id, operation: id)
            try Task.checkCancellation()
            guard redemptions.records[id]?.result.state == .pending else { return }
            record.result.providerResult = verdict
            switch verdict.code {
            case "reset", "already_redeemed": record.result.state = .confirmed
            case "nothing_to_reset": record.result.state = .nothing_to_reset
            default: record.result.state = .no_credit
            }
        } catch {
            guard redemptions.records[id]?.result.state == .pending else { return }
            // A failed marker commit never reaches consume. If retaining that known failure
            // also fails, the journal keeps a conservative block for the possible durable marker.
            if consumeAttempted { record.interrupt(at: clock()) }
            else {
                record.result.state = .failed
                record.result.error = error as? Fault ?? Fault("provider_unavailable", "Credit preflight did not complete. No consume was sent.")
            }
            if consumeAttempted, let credential, record.namespace == databaseIdentity {
                var policy = attempts[accountID]?["reset-credits"] ?? AttemptPolicy()
                let fault = policy.finish(at: clock(), fault: error as? Fault ?? Fault("provider_response_unknown", "The consume response was lost."), credential: credential.fingerprint)
                attempts[accountID, default: [:]]["reset-credits"] = policy
                record.result.error?.retryAt = fault?.retryAt
                persist()
            }
            if preflightStarted && !preflightFinished, let credential {
                finish(key: JobKey(account: accountID, job: "reset-credits"), credential: credential.fingerprint,
                       namespace: record.namespace, groups: [.resetDetails], result: .failure(record.result.error ?? Fault("provider_unavailable", "Credit preflight failed.")))
            }
        }
        completeRedemption(record)
    }

    private func completeRedemption(_ original: RedemptionRecord) {
        var record = original
        record.result.updatedAt = clock()
        do { try redemptions.save(record) }
        catch { redemptions.retainUncommitted(record, at: clock()) }
        redemptionTasks[record.result.operationId] = nil
        if !stopping, inventory.error == nil, record.namespace == databaseIdentity, credentials[record.result.accountId] != nil {
            if record.maySend, let index = accounts.firstIndex(where: { $0.id == record.result.accountId }) {
                accounts[index].groups.quotas.stale = true
                accounts[index].groups.resetDetails.stale = true
                accounts[index].groups.resetSummary.stale = true
            }
            _ = schedule(id: record.result.accountId, at: clock(), automatic: false)
        }
    }

    func waitForRedemptions() async {
        for task in Array(redemptionTasks.values) { await task.value }
    }
}
