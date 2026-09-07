import Foundation
import Testing
@testable import TallyCore
@testable import TallyApp

@Test @MainActor func redemptionNativeControlsRetainOwnerIdentityAndRequireDurableAcknowledgement() async throws {
    let scenario = ResetScenario()
    let gate = ResetGate()
    let owner = scenario.owner(transport: { request in
        if request.httpMethod == "POST" { await gate.wait() }
        return try scenario.transport(request, body: #"{"code":"unrecognized"}"#)
    })
    let id = try await resetAccount(owner)
    let account = try await owner.account(id: id).account
    let runtime = Runtime(owner: owner)
    let credit = Credit(id: "credit-a", status: "available", available: true, expiry: Credit.Expiry(kind: "unknown"))
    await runtime.redeem(account, credit: credit)
    let operationID = try #require(runtime.resetOperations[id]?.operationId)
    await runtime.redeem(account, credit: credit)
    #expect(runtime.resetOperations[id]?.operationId == operationID)
    await gate.open(); await owner.waitForRedemptions()
    await runtime.readResetState()
    #expect(runtime.resetOperations[id]?.acknowledgementRequired == true)
    let reopened = Runtime(owner: owner)
    await reopened.readResetState()
    #expect(reopened.resetOperations[id]?.operationId == operationID)
    #expect(reopened.resetOperations[id]?.displayMessage(for: account).contains("never retries") == true)
    scenario.fail(on: [4])
    await reopened.acknowledgeReset(account)
    #expect(reopened.resetOperations[id]?.acknowledgementRequired == true)
    #expect(reopened.resetErrors[id]?.contains("not confirmed") == true)
    scenario.fail(on: [])
    await reopened.acknowledgeReset(account)
    #expect(reopened.resetOperations[id]?.state == .unknown)
    #expect(reopened.resetOperations[id]?.acknowledgementRequired == false)
    #expect(scenario.calls().filter { $0.httpMethod == "POST" }.count == 1)
    await owner.shutdown()
}

@Test func redemptionPresentationKeepsExpiryAndConfirmedCollectionFailureDistinct() throws {
    var account = try Wire.decoder().decode(AccountsResponse.self, from: fixture("accounts")).accounts[0]
    let operation = try Wire.decoder().decode([Redemption].self, from: fixture("redemptions"))[3]
    #expect(operation.displayMessage(for: account) == "Reset confirmed; usage update unavailable")
    account.groups.quotas.stale = false; account.groups.quotas.error = nil
    #expect(operation.displayMessage(for: account) == "Credit already redeemed; no additional reset claimed.")
    var credit = Credit(id: "a", status: "available", available: true, expiry: Credit.Expiry(kind: "unknown"))
    #expect(credit.isUsable)
    credit.expiry = Credit.Expiry(kind: "none")
    #expect(credit.isUsable)
    credit.expiry = Credit.Expiry(kind: "at", at: Date(timeIntervalSince1970: 0))
    #expect(!credit.isUsable)
    credit.available = nil
    #expect(!credit.isUsable)
}

actor ResetGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func open() { opened = true; for item in continuations { item.resume() }; continuations = [] }
}

final class ResetScenario: @unchecked Sendable {
    private let lock = NSLock()
    let now = Date(timeIntervalSince1970: 1_915_031_000)
    private var source = InventoryRead(databaseIdentity: "reset-db", credentials: [StoredCredential(storedID: "a", name: "Personal", key: "synthetic-access", provider: "openai", workspace: "workspace-a")])
    private var records: [String: RedemptionRecord] = [:]
    private var history: [RedemptionRecord] = []
    private var requests: [URLRequest] = []
    private var failWrites: Set<Int> = []
    private var failAfterCommit = false
    private var writes = 0
    private var inventoryFailure = false

    func read() throws -> InventoryRead { try lock.withLock { if inventoryFailure { throw Fault("inventory_unavailable", "Synthetic inventory failure") }; return source } }
    func replace(_ credentials: [StoredCredential], namespace: String = "reset-db") { lock.withLock { source = InventoryRead(databaseIdentity: namespace, credentials: credentials) } }
    func failInventory() { lock.withLock { inventoryFailure = true } }
    func retained() -> [RedemptionRecord] { lock.withLock { Array(records.values) } }
    func snapshots() -> [RedemptionRecord] { lock.withLock { history } }
    func calls() -> [URLRequest] { lock.withLock { requests } }
    func fail(on writes: Set<Int>, afterCommit: Bool = false) { lock.withLock { failWrites = writes; failAfterCommit = afterCommit } }
    func seed(_ rows: [RedemptionRecord]) { lock.withLock { records = Dictionary(uniqueKeysWithValues: rows.map { ($0.result.operationId, $0) }) } }

    var storage: RedemptionStorage {
        RedemptionStorage(load: { self.retained() }, save: { record in
            try self.lock.withLock {
                self.writes += 1
                let fail = self.failWrites.contains(self.writes)
                if fail && !self.failAfterCommit { throw recoveryFault() }
                self.records[record.result.operationId] = record; self.history.append(record)
                if fail { throw recoveryFault() }
            }
        })
    }

    func transport(_ request: URLRequest, body: String = #"{"code":"reset"}"#, status: Int = 200) throws -> ResetHTTPResponse {
        lock.withLock {
            requests.append(request)
            let matching = records.values.first { record in
                record.target.workspace == request.value(forHTTPHeaderField: "ChatGPT-Account-Id").map(identityDigest) && record.result.state == .pending
            }
            #expect(matching != nil, "Original request must be durable before any provider request")
            #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer synthetic-") == true)
            if request.httpMethod == "POST" {
                #expect(matching?.maySend == true)
                #expect(matching?.result.selectedCreditId == "credit-a")
                #expect(request.timeoutInterval == 15)
                #expect(request.url?.path == "/backend-api/wham/rate-limit-reset-credits/consume")
                let payload = try? JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String]
                #expect(payload?["credit_id"] == matching?.result.selectedCreditId)
                #expect(payload?["redeem_request_id"] == matching?.result.operationId)
            } else {
                #expect(matching?.maySend == false)
                #expect(request.timeoutInterval == 10)
                #expect(request.httpBody == nil)
            }
        }
        if request.httpMethod == "GET" {
            return ResetHTTPResponse(status: 200, body: Data(#"{"credits":[{"id":"credit-a","status":"available","expires_at":null}],"available_count":1,"applicable_available_count":0}"#.utf8))
        }
        return ResetHTTPResponse(status: status, body: Data(body.utf8))
    }

    func owner(transport: (@Sendable (URLRequest) async throws -> ResetHTTPResponse)? = nil, storageURL: URL? = nil, quitWait: Duration = .seconds(15), collections: (@Sendable (StoredCredential) -> [CollectionJob])? = nil) -> TallyOwner {
        TallyOwner(clock: { self.now }, storageURL: storageURL, redemptionStorage: storage,
                   resetProvider: OpenAIRedemption(transport: transport ?? { try self.transport($0) }), quitWait: quitWait,
                   inventory: { try self.read() }, collections: collections, collect: { _ in throw Fault("unexpected", "No Go request") })
    }
}

func resetAccount(_ owner: TallyOwner) async throws -> String {
    try await owner.refresh(accountIDs: [])
    return try #require(await owner.snapshot().accounts.first?.id)
}

@Test(arguments: ["reset", "already_redeemed", "nothing_to_reset", "no_credit"])
func redemptionRecognizedOutcomesAndOriginalUUID(code: String) async throws {
    let scenario = ResetScenario()
    let owner = scenario.owner(transport: { try scenario.transport($0, body: "{\"code\":\"\(code)\",\"windows_reset\":null}") })
    let account = try await resetAccount(owner)
    let id = UUID().uuidString
    let accepted = try await owner.submitRedemption(accountID: account, operationID: id.lowercased())
    #expect(accepted.state == .pending && accepted.operationId == id)
    #expect(accepted.requestedCreditId == nil && accepted.selectedCreditId == nil)
    await owner.waitForRedemptions()
    let result = try await owner.redemption(operationID: id)
    #expect(result.state.rawValue == (["reset", "already_redeemed"].contains(code) ? "confirmed" : code))
    #expect(result.providerResult?.code == code && result.providerResult?.windowsReset == nil)
    #expect(result.selectedCreditId == "credit-a" && result.requestedCreditId == nil)
    #expect(!result.acknowledgementRequired)
    let repeated = try await owner.submitRedemption(accountID: account, operationID: id)
    #expect(try Wire.encoder().encode(repeated) == Wire.encoder().encode(result))
    await #expect(throws: Fault.self) { try await owner.submitRedemption(accountID: account, operationID: id, creditID: "credit-a") }
    await #expect(throws: Fault.self) { try await owner.acknowledgeRedemption(operationID: id) }
    #expect(scenario.calls().map(\.httpMethod) == ["GET", "POST"])
    let restarted = scenario.owner()
    #expect(try await restarted.redemption(operationID: id).state == result.state)
    #expect(try await restarted.submitRedemption(accountID: account, operationID: id).selectedCreditId == "credit-a")
    let data = try Wire.encoder().encode(scenario.retained())
    #expect(!String(decoding: data, as: UTF8.self).contains("synthetic-access"))
    #expect(!String(decoding: data, as: UTF8.self).contains("workspace-a"))
    await owner.shutdown(); await restarted.shutdown()
}

@Test func redemptionExpiryOrderAndExplicitSelection() throws {
    let now = Date(timeIntervalSince1970: 1000)
    func credit(_ id: String, _ kind: String, _ at: Date? = nil, status: String = "available", available: Bool? = true) -> Credit {
        Credit(id: id, status: status, available: available, expiry: Credit.Expiry(kind: kind, at: at))
    }
    let credits = [credit("unknown", "unknown"), credit("none", "none"), credit("later", "at", now.addingTimeInterval(2)),
                   credit("b", "at", now.addingTimeInterval(1)), credit("a", "at", now.addingTimeInterval(1)),
                   credit("expired", "at", now), credit("spent", "none", status: "redeemed"), credit("", "none"), credit("status-unknown", "none", status: "new", available: nil)]
    var details = ResetDetails(credits: credits, summary: ResetSummary(availableCount: 99, applicableAvailableCount: 0, source: "credit_details"))
    var order: [String] = []
    while let item = selectCredit(details, requested: nil, at: now) { order.append(item.id); details.credits.removeAll { $0.id == item.id } }
    #expect(order == ["a", "b", "later", "none", "unknown"])
    details.credits = credits
    #expect(selectCredit(details, requested: "unknown", at: now)?.id == "unknown")
    for id in ["expired", "spent", "missing", "status-unknown"] { #expect(selectCredit(details, requested: id, at: now) == nil) }
}

@Test(arguments: ["lost", "cancel", "{}", "{\"code\":\"new_code\"}", "{\"code\":\"reset\",\"windows_reset\":-1}", "{\"code\":\"reset\",\"windows_reset\":\"2\"}", "HTTP500"])
func redemptionAmbiguityNeverRetriesAndAcknowledgementIsDurable(outcome: String) async throws {
    let scenario = ResetScenario()
    let owner = scenario.owner(transport: { request in
        let response = try scenario.transport(request, body: outcome, status: outcome == "HTTP500" ? 500 : 200)
        if request.httpMethod == "POST" {
            if outcome == "lost" { throw URLError(.networkConnectionLost) }
            if outcome == "cancel" { throw CancellationError() }
        }
        return response
    })
    let account = try await resetAccount(owner)
    let id = UUID().uuidString
    _ = try await owner.submitRedemption(accountID: account, operationID: id)
    await owner.waitForRedemptions()
    #expect(try await owner.redemption(operationID: id).state == .unknown)
    #expect(try await owner.account(id: account).account.command.blockingOperationId == id)
    do { _ = try await owner.submitRedemption(accountID: account, operationID: UUID().uuidString); Issue.record("Unknown must block") }
    catch let fault as Fault { #expect(fault.code == "account_blocked" && fault.blockingOperationId == id) }
    _ = try await owner.submitRedemption(accountID: account, operationID: id)
    scenario.fail(on: [4])
    await #expect(throws: Fault.self) { try await owner.acknowledgeRedemption(operationID: id) }
    #expect(try await owner.redemption(operationID: id).acknowledgementRequired)
    #expect(try await owner.account(id: account).account.command.blockingOperationId == id)
    scenario.fail(on: [])
    let acknowledged = try await owner.acknowledgeRedemption(operationID: id)
    #expect(acknowledged.state == .unknown && acknowledged.acknowledgedAt != nil && !acknowledged.acknowledgementRequired)
    #expect(try await owner.acknowledgeRedemption(operationID: id).acknowledgedAt == acknowledged.acknowledgedAt)
    #expect(try await owner.account(id: account).account.command.blockingOperationId == nil)
    let restarted = scenario.owner()
    #expect(try await restarted.redemption(operationID: id).acknowledgedAt == acknowledged.acknowledgedAt)
    #expect(scenario.calls().count == 2)
    await owner.shutdown(); await restarted.shutdown()
}

@Test(arguments: [1, 2, 3], [false, true])
func redemptionStorageFailureAtEveryCommit(write: Int, afterCommit: Bool) async throws {
    let scenario = ResetScenario()
    scenario.fail(on: [write], afterCommit: afterCommit)
    let owner = scenario.owner()
    let account = try await resetAccount(owner)
    let id = UUID().uuidString
    if write == 1 {
        await #expect(throws: Fault.self) { try await owner.submitRedemption(accountID: account, operationID: id) }
        #expect(scenario.calls().isEmpty)
        #expect(try await owner.redemption(operationID: id).state == .failed)
    } else {
        _ = try await owner.submitRedemption(accountID: account, operationID: id)
        await owner.waitForRedemptions()
        #expect(scenario.calls().filter { $0.httpMethod == "POST" }.count == (write == 3 ? 1 : 0))
        #expect(try await owner.redemption(operationID: id).state == (write == 2 ? .failed : .unknown))
        #expect(try await owner.account(id: account).account.command.blockingOperationId == (write == 2 ? nil : id))
    }
    scenario.fail(on: [])
    let restarted = scenario.owner()
    if !scenario.retained().isEmpty {
        let recovered = try await restarted.redemption(operationID: id)
        if write == 3 && afterCommit { #expect(recovered.state == .confirmed) }
        else { #expect(recovered.state == (write == 3 ? .unknown : .failed)) }
    }
    #expect(scenario.calls().filter { $0.httpMethod == "POST" }.count <= 1)
    await owner.shutdown(); await restarted.shutdown()
}

@Test func redemptionRecoveryAtAcceptedAndMaySendSnapshotsNeverResumes() async throws {
    let scenario = ResetScenario()
    let owner = scenario.owner()
    let account = try await resetAccount(owner)
    let id = UUID().uuidString
    _ = try await owner.submitRedemption(accountID: account, operationID: id)
    await owner.waitForRedemptions()
    let snapshots = scenario.snapshots()
    #expect(snapshots.count == 3)
    for snapshot in snapshots {
        let crash = ResetScenario(); crash.seed([snapshot])
        let recovered = crash.owner()
        let result = try await recovered.redemption(operationID: id)
        #expect(result.state == (snapshot.result.state == .confirmed ? .confirmed : snapshot.maySend ? .unknown : .failed))
        _ = try await recovered.submitRedemption(accountID: account, operationID: id)
        #expect(crash.calls().isEmpty)
        await recovered.shutdown()
    }
    await owner.shutdown()
}

@Test func redemptionAccountsProceedIndependentlyWhileDuplicateUUIDJoins() async throws {
    let scenario = ResetScenario()
    let a = StoredCredential(storedID: "a", name: "A", key: "synthetic-shared", provider: "openai", workspace: "workspace-a")
    let b = StoredCredential(storedID: "b", name: "B", key: "synthetic-shared", provider: "openai", workspace: "workspace-b")
    scenario.replace([a, b])
    let gate = ResetGate()
    let (entered, signal) = AsyncStream<Bool>.makeStream()
    let owner = scenario.owner(transport: { request in
        let result = try scenario.transport(request)
        if request.httpMethod == "POST", request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "workspace-a" {
            signal.yield(true); signal.finish(); await gate.wait()
        }
        return result
    })
    let account = try await resetAccount(owner)
    let second = try #require(await owner.snapshot().accounts.last?.id)
    let id = UUID().uuidString
    _ = try await owner.submitRedemption(accountID: account, operationID: id)
    #expect(await entered.first(where: { _ in true }) == true)
    let duplicate = try await owner.submitRedemption(accountID: account, operationID: id)
    #expect(duplicate.state == .pending && duplicate.selectedCreditId == "credit-a" && duplicate.requestedCreditId == nil)
    await #expect(throws: Fault.self) { try await owner.submitRedemption(accountID: second, operationID: id) }
    await #expect(throws: Fault.self) { try await owner.submitRedemption(accountID: account, operationID: UUID().uuidString) }
    let secondID = UUID().uuidString
    _ = try await owner.submitRedemption(accountID: second, operationID: secondID)
    // Reading the unrelated operation waits on neither provider nor the blocked Account.
    for _ in 0..<100 where try await owner.redemption(operationID: secondID).state == .pending { try await Task.sleep(for: .milliseconds(1)) }
    #expect(try await owner.redemption(operationID: secondID).state == .confirmed)
    #expect(try await owner.redemption(operationID: id).state == .pending)
    await gate.open(); await owner.waitForRedemptions()
    #expect(scenario.calls().filter { $0.httpMethod == "POST" }.count == 2)
    await owner.shutdown()
}

@Test func redemptionUnknownBlocksSameAndUncertainTargetsAcrossNamespaces() async throws {
    let scenario = ResetScenario()
    let owner = scenario.owner(transport: { request in
        let response = try scenario.transport(request)
        if request.httpMethod == "POST" { throw URLError(.timedOut) }; return response
    })
    let account = try await resetAccount(owner)
    let id = UUID().uuidString
    _ = try await owner.submitRedemption(accountID: account, operationID: id)
    await owner.waitForRedemptions()
    scenario.replace([], namespace: "removed")
    try await owner.refresh(accountIDs: [])
    #expect(try await owner.redemption(operationID: id).accountId == account)
    for workspace in ["workspace-a", nil] as [String?] {
        scenario.replace([StoredCredential(storedID: "new", name: "Replacement", key: "synthetic-new", provider: "openai", workspace: workspace)], namespace: UUID().uuidString)
        let replacement = try await resetAccount(owner)
        #expect(replacement != account)
        #expect(try await owner.account(id: replacement).account.command.blockingOperationId == id)
        do { _ = try await owner.submitRedemption(accountID: replacement, operationID: UUID().uuidString); Issue.record("Identity block bypassed") }
        catch let fault as Fault { #expect(fault.blockingOperationId == id) }
    }
    scenario.replace([StoredCredential(storedID: "other", name: "Independent", key: "synthetic-new", provider: "openai", workspace: "workspace-b")], namespace: "different")
    let independent = try await resetAccount(owner)
    _ = try await owner.submitRedemption(accountID: independent, operationID: UUID().uuidString)
    await owner.waitForRedemptions()
    #expect(scenario.calls().filter { $0.httpMethod == "POST" }.count == 2)
    #expect(try await owner.submitRedemption(accountID: account, operationID: id).state == .unknown)
    await owner.shutdown()
}

@Test(arguments: ["namespace", "replacement", "removal", "rotation", "inventory"])
func redemptionRechecksTargetAfterPreflight(change: String) async throws {
    let scenario = ResetScenario()
    let owner = scenario.owner(transport: { request in
        let response = try scenario.transport(request)
        if request.httpMethod == "GET" {
            switch change {
            case "namespace": scenario.replace(try scenario.read().credentials, namespace: "new-db")
            case "replacement": scenario.replace([StoredCredential(storedID: "a", name: "Personal", key: "synthetic-new", provider: "openai", workspace: "different")])
            case "removal": scenario.replace([])
            case "rotation": scenario.replace([StoredCredential(storedID: "a", name: "Personal", key: "synthetic-rotated", provider: "openai", workspace: "workspace-a")])
            default: scenario.failInventory()
            }
        }
        return response
    }, collections: { _ in
        change == "inventory" ? [CollectionJob(id: "usage", groups: [.quotas]) {
            Issue.record("An unreadable inventory must not authorize post-outcome collection with cached credentials")
            return [.quotas(nil)]
        }] : []
    })
    let account = try await resetAccount(owner)
    let id = UUID().uuidString
    _ = try await owner.submitRedemption(accountID: account, operationID: id)
    await owner.waitForRedemptions()
    #expect(try await owner.redemption(operationID: id).state == .failed)
    #expect(scenario.calls().map(\.httpMethod) == ["GET"])
    if change == "inventory" {
        #expect(try await owner.account(id: account).account.groups.quotas.stale)
        #expect(try await owner.account(id: account).account.groups.quotas.error?.code == "inventory_unavailable")
    }
    await owner.shutdown()
}

@Test func redemptionUsesCurrentCredentialsAndHonorsPersistedPreflightCooldown() async throws {
    let scenario = ResetScenario()
    let owner = scenario.owner()
    let account = try await resetAccount(owner)
    scenario.replace([StoredCredential(storedID: "a", name: "Renamed", key: "synthetic-rotated", provider: "openai", workspace: "workspace-a")])
    let id = UUID().uuidString
    _ = try await owner.submitRedemption(accountID: account, operationID: id)
    await owner.waitForRedemptions()
    #expect(scenario.calls().allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-rotated" })
    let next = UUID().uuidString
    _ = try await owner.submitRedemption(accountID: account, operationID: next)
    await owner.waitForRedemptions()
    #expect(try await owner.redemption(operationID: next).state == .confirmed)
    #expect(scenario.calls().map(\.httpMethod) == ["GET", "POST", "GET", "POST"])
    await owner.shutdown()

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("accounts.json")
    let cooling = ResetScenario()
    let first = cooling.owner(storageURL: url, collections: { _ in [CollectionJob(id: "reset-credits", groups: [.resetDetails]) {
        var fault = Fault("provider_unavailable", "Synthetic cooldown"); fault.retryAt = cooling.now.addingTimeInterval(3600); throw fault
    }] })
    try await first.refresh(); await first.waitForCollection(); await first.shutdown()
    let restarted = cooling.owner(storageURL: url)
    let restoredAccount = try await resetAccount(restarted)
    let operation = UUID().uuidString
    _ = try await restarted.submitRedemption(accountID: restoredAccount, operationID: operation)
    await restarted.waitForRedemptions()
    #expect(try await restarted.redemption(operationID: operation).error?.retryAt == cooling.now.addingTimeInterval(3600))
    #expect(cooling.calls().isEmpty)
    await restarted.shutdown()
}

@Test(arguments: ["completed", "running", "cooldown", "rejected", "removal", "shutdown"])
func redemptionJoinsRoutineCreditCollectionWithoutRefreshDebounce(outcome: String) async throws {
    let scenario = ResetScenario()
    let gate = ResetGate()
    let (entered, signal) = AsyncStream<Bool>.makeStream()
    let owner = scenario.owner(quitWait: .milliseconds(40), collections: { _ in
        [CollectionJob(id: "reset-credits", groups: [.resetDetails]) {
            signal.yield(true); signal.finish(); await gate.wait()
            if outcome == "cooldown" {
                var fault = Fault("provider_unavailable", "Synthetic cooldown")
                fault.retryAt = scenario.now.addingTimeInterval(3600)
                throw fault
            }
            if outcome == "rejected" { throw Fault("credentials_rejected", "Synthetic rejection") }
            return [.resetDetails(nil)]
        }]
    })
    try await owner.refresh()
    #expect(await entered.first(where: { _ in true }) == true)
    let account = try #require(await owner.snapshot().accounts.first?.id)
    if outcome == "completed" { await gate.open(); await owner.waitForCollection() }
    let id = UUID().uuidString
    _ = try await owner.submitRedemption(accountID: account, operationID: id)
    if outcome != "completed" {
        #expect(try await owner.redemption(operationID: id).state == .pending)
        #expect(scenario.calls().isEmpty)
    }
    if outcome == "removal" { scenario.replace([]) }
    if outcome == "shutdown" { await owner.shutdown() }
    await gate.open(); await owner.waitForCollection(); await owner.waitForRedemptions()
    let result = try await owner.redemption(operationID: id)
    if outcome == "completed" || outcome == "running" {
        #expect(result.state == .confirmed)
        #expect(scenario.calls().map(\.httpMethod) == ["GET", "POST"])
    } else {
        #expect(result.state == .failed)
        #expect(scenario.calls().isEmpty)
        if outcome == "cooldown" { #expect(result.error?.retryAt == scenario.now.addingTimeInterval(3600)) }
        if outcome == "rejected" || outcome == "removal" { #expect(result.error?.code == "credentials_unavailable") }
    }
    await owner.shutdown()
}

@Test(arguments: [false, true])
func redemptionQuitIsBoundedWithCancellationIgnoringTransport(afterMarker: Bool) async throws {
    let scenario = ResetScenario()
    let gate = ResetGate()
    let (entered, signal) = AsyncStream<Bool>.makeStream()
    let owner = scenario.owner(transport: { request in
        let response = try scenario.transport(request)
        if (request.httpMethod == "POST") == afterMarker {
            signal.yield(true); signal.finish(); await gate.wait()
        }
        return response
    }, quitWait: .milliseconds(40))
    let account = try await resetAccount(owner)
    let id = UUID().uuidString
    _ = try await owner.submitRedemption(accountID: account, operationID: id)
    #expect(await entered.first(where: { _ in true }) == true)
    let start = ContinuousClock.now
    await owner.shutdown()
    #expect(start.duration(to: .now) < .seconds(1))
    #expect(try await owner.redemption(operationID: id).state == (afterMarker ? .unknown : .failed))
    do { _ = try await owner.submitRedemption(accountID: account, operationID: UUID().uuidString); Issue.record("Shutdown accepted work") }
    catch let fault as Fault { #expect(fault.code == "shutting_down") }
    let recovered = scenario.owner()
    #expect(try await recovered.redemption(operationID: id).state == (afterMarker ? .unknown : .failed))
    await gate.open()
    try await Task.sleep(for: .milliseconds(10))
    #expect(try await owner.redemption(operationID: id).state == (afterMarker ? .unknown : .failed))
    #expect(scenario.calls().filter { $0.httpMethod == "POST" }.count == (afterMarker ? 1 : 0))
    await recovered.shutdown()
}

@Test func redemptionSQLiteRetainsRecordsAndRefusesCorruptionOrSecondOwner() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("redemptions.sqlite")
    let now = Date()
    let id = UUID().uuidString
    let result = Redemption(operationId: id, accountId: "opaque", accountName: "Fixture", createdAt: now, updatedAt: now, resultUrl: "/api/v1/redemptions/\(id)")
    let row = RedemptionRecord(result: result, namespace: "namespace", target: IdentityEvidence(provider: "openai", workspace: "hash", tokens: []))
    do {
        var journal = RedemptionJournal(storage: .disk(url), now: now)
        #expect(journal.error == nil)
        try journal.save(row)
        let second = RedemptionJournal(storage: .disk(url), now: now)
        #expect(second.error?.code == "recovery_storage_unavailable")
    }
    do {
        var reopened = RedemptionJournal(storage: .disk(url), now: now)
        #expect(reopened.records[id]?.result.state == .failed)
        #expect(reopened.error == nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        var marker = row
        marker.maySend = true; marker.result.selectedCreditId = "credit-a"
        try reopened.save(marker)
    }
    do {
        var recovered = RedemptionJournal(storage: .disk(url), now: now)
        var unknown = try #require(recovered.records[id])
        #expect(unknown.result.state == .unknown && unknown.blocking)
        unknown.result.acknowledgedAt = now; unknown.result.acknowledgementRequired = false
        try recovered.save(unknown)
    }
    do {
        var acknowledged = RedemptionJournal(storage: .disk(url), now: now)
        #expect(acknowledged.records[id]?.result.state == .unknown)
        #expect(acknowledged.records[id]?.blocking == false)
        let previous = directory.appendingPathComponent("previous.sqlite")
        try FileManager.default.moveItem(at: url, to: previous)
        try Data("replacement".utf8).write(to: url)
        #expect(throws: Fault.self) { try acknowledged.save(row) }
    }
    try Data("corrupt".utf8).write(to: url)
    var corrupt = RedemptionJournal(storage: .disk(url), now: now)
    #expect(corrupt.error?.code == "recovery_storage_unavailable")
    #expect(throws: Fault.self) { try corrupt.save(row) }
}

@Test func redemptionSingleSendHTTPFramingDoesNotFollowRedirectsOrAcceptTruncation() throws {
    let credential = StoredCredential(storedID: "a", name: "A", key: "synthetic-key", provider: "openai", workspace: "synthetic-workspace")
    let request = try OpenAIRedemption().request(credential, credit: "credit", operation: UUID().uuidString)
    let bytes = try SingleSendHTTP.encode(request)
    let text = String(decoding: bytes, as: UTF8.self)
    #expect(text.hasPrefix("POST /backend-api/wham/rate-limit-reset-credits/consume HTTP/1.1\r\n"))
    #expect(text.contains("Connection: close\r\n") && text.contains("Accept-Encoding: identity\r\n"))
    let body = #"{"code":"reset"}"#
    let fixed = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
    for count in 0..<fixed.count { #expect(try SingleSendHTTP.decode(Data(fixed.prefix(count)), complete: false) == nil) }
    #expect(try SingleSendHTTP.decode(fixed, complete: false)?.body == Data(body.utf8))
    let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\(String(body.utf8.count, radix: 16))\r\n\(body)\r\n0\r\n\r\n".utf8)
    #expect(try SingleSendHTTP.decode(chunked, complete: false)?.body == Data(body.utf8))
    for invalid in ["HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\n{}", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}"] {
        #expect(throws: Fault.self) { try SingleSendHTTP.decode(Data(invalid.utf8), complete: true) }
    }
    #expect(try SingleSendHTTP.decode(Data("HTTP/1.1 307 Redirect\r\nLocation: https://example.com\r\nContent-Length: 0\r\n\r\n".utf8), complete: true)?.status == 307)
}

@Test(arguments: ["no_credit", "timeout", "rejected", "expired", "workspace"])
func redemptionPreflightEndsWithoutQueuedSpend(reason: String) async throws {
    let scenario = ResetScenario()
    let owner = scenario.owner(transport: { request in
        let response = try scenario.transport(request)
        if reason == "timeout" { throw URLError(.timedOut) }
        if reason == "rejected" { return ResetHTTPResponse(status: 401, body: Data("private provider text".utf8)) }
        return response
    })
    let account = try await resetAccount(owner)
    if reason == "expired" || reason == "workspace" {
        scenario.replace([StoredCredential(storedID: "a", name: "Personal", key: "synthetic-access", provider: "openai", workspace: reason == "workspace" ? nil : "workspace-a", expiresAt: reason == "expired" ? .distantPast : nil)])
    }
    let id = UUID().uuidString
    _ = try await owner.submitRedemption(accountID: account, operationID: id, creditID: reason == "no_credit" ? "not-listed" : nil)
    await owner.waitForRedemptions()
    let result = try await owner.redemption(operationID: id)
    #expect(result.state == (reason == "no_credit" ? .no_credit : .failed))
    #expect(result.providerResult == nil && !result.acknowledgementRequired)
    #expect(scenario.calls().allSatisfy { $0.httpMethod == "GET" })
    #expect(!String(decoding: try Wire.encoder().encode(result), as: UTF8.self).contains("private provider text"))
    let priorCount = scenario.calls().count
    _ = try await owner.submitRedemption(accountID: account, operationID: id, creditID: reason == "no_credit" ? "not-listed" : nil)
    await owner.waitForRedemptions()
    #expect(scenario.calls().count == priorCount)
    await owner.shutdown()
}

@Test func redemptionConfirmationSurvivesRefreshFailureAndClientDisconnect() async throws {
    let scenario = ResetScenario()
    let gate = ResetGate()
    let (entered, signal) = AsyncStream<Bool>.makeStream()
    let owner = scenario.owner(transport: { request in
        let response = try scenario.transport(request, body: #"{"code":"reset","windows_reset":2}"#)
        if request.httpMethod == "POST" { signal.yield(true); signal.finish(); await gate.wait() }
        return response
    }, collections: { _ in [CollectionJob(id: "usage", groups: [.quotas]) { throw Fault("provider_unavailable", "Synthetic refresh failure") }] })
    let account = try await resetAccount(owner)
    let id = UUID().uuidString
    let browser = Task { try await owner.submitRedemption(accountID: account, operationID: id) }
    #expect(try await browser.value.state == .pending)
    #expect(await entered.first(where: { _ in true }) == true)
    browser.cancel()
    await gate.open(); await owner.waitForRedemptions(); await owner.waitForCollection()
    #expect(try await owner.redemption(operationID: id).state == .confirmed)
    #expect(try await owner.redemption(operationID: id).providerResult?.windowsReset == 2)
    #expect(try await owner.account(id: account).account.groups.quotas.stale)
    #expect(try await owner.account(id: account).account.groups.quotas.error?.code == "provider_unavailable")
    #expect(scenario.calls().filter { $0.httpMethod == "POST" }.count == 1)
    await owner.shutdown()
}

@Test func redemptionSharedWireFixtureKeepsRequiredNullFields() throws {
    let data = try fixture("redemptions")
    let operations = try Wire.decoder().decode([Redemption].self, from: data)
    #expect(operations.map(\.state) == [.pending, .unknown, .unknown, .confirmed])
    #expect(operations[1].requestedCreditId == nil && operations[1].selectedCreditId == "credit-a")
    #expect(operations[1].acknowledgementRequired && operations[1].acknowledgedAt == nil)
    #expect(!operations[2].acknowledgementRequired && operations[2].acknowledgedAt != nil)
    #expect(operations[3].providerResult?.code == "already_redeemed" && operations[3].providerResult?.windowsReset == nil)
    let original = try JSONSerialization.jsonObject(with: data) as? NSArray
    let encoded = try JSONSerialization.jsonObject(with: Wire.encoder().encode(operations)) as? NSArray
    #expect(original == encoded)
}

@Test func redemptionRetainsReceivedVerdictUntilStorageRecoversWithoutResending() async throws {
    let scenario = ResetScenario()
    scenario.fail(on: [3])
    let owner = scenario.owner()
    let account = try await resetAccount(owner)
    let id = UUID().uuidString
    _ = try await owner.submitRedemption(accountID: account, operationID: id)
    await owner.waitForRedemptions()
    #expect(try await owner.redemption(operationID: id).state == .unknown)
    #expect(!(await owner.snapshot().status.recoveryStorage.available))
    scenario.fail(on: [])
    await owner.tick()
    #expect(try await owner.redemption(operationID: id).state == .confirmed)
    #expect(await owner.snapshot().status.recoveryStorage.available)
    #expect(try await owner.account(id: account).account.command.blockingOperationId == nil)
    #expect(scenario.calls().filter { $0.httpMethod == "POST" }.count == 1)
    let restarted = scenario.owner()
    #expect(try await restarted.redemption(operationID: id).state == .confirmed)
    await owner.shutdown(); await restarted.shutdown()
}

@Test func redemptionMarkerAndFailurePersistenceBothUnavailableKeepConservativeBlock() async throws {
    let scenario = ResetScenario()
    scenario.fail(on: [2, 3])
    let owner = scenario.owner()
    let account = try await resetAccount(owner)
    let id = UUID().uuidString
    _ = try await owner.submitRedemption(accountID: account, operationID: id)
    await owner.waitForRedemptions()
    #expect(try await owner.redemption(operationID: id).state == .unknown)
    #expect(try await owner.account(id: account).account.command.blockingOperationId == id)
    #expect(scenario.calls().map(\.httpMethod) == ["GET"])
    scenario.fail(on: [])
    await owner.tick()
    #expect(try await owner.redemption(operationID: id).state == .failed)
    #expect(try await owner.account(id: account).account.command.blockingOperationId == nil)
    #expect(scenario.calls().map(\.httpMethod) == ["GET"])
    await owner.shutdown()
}
