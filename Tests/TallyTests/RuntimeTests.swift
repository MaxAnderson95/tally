import Foundation
import Testing
import CSQLite
import AppKit
import SwiftUI
@testable import TallyCore
@testable import TallyApp

func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!)
}

@Test @MainActor func nativePresentationReference() throws {
    // Opt-in image evidence uses the real native views without starting the runtime or collection.
    guard let output = ProcessInfo.processInfo.environment["TALLY_PRESENTATION_OUTPUT"] else { return }
    _ = NSApplication.shared
    let runtime = Runtime(owner: ResetScenario().owner())
    var snapshot = try Wire.decoder().decode(AccountsResponse.self, from: fixture("accounts"))
    let base = snapshot.accounts[0]
    let now = Date()
    snapshot.accounts = try (0..<14).map { index in
        var account = base
        account.id = "native-\(index)"; account.name = index == 0 ? "Personal with a deliberately long Account name" : "Account \(index + 1)"
        account.provider = ["anthropic", "openai", "opencode-go", "xai"][index % 4]
        account.identityColorIndex = index % 6; account.pinOrder = index
        account.groups = AccountGroups()
        let observations: [GroupObservation]
        switch account.provider {
        case "anthropic": observations = try AnthropicUsage.decode(fixture("anthropic-usage"))
        case "openai": observations = try OpenAIUsage.decodeUsage(fixture("openai-usage"), at: now)
        case "xai": observations = try GrokUsage.decode(fixture("grok-billing"))
        default:
            let go = try GoUsage.decode(fixture("go-valid"))
            observations = [.plan(Plan(name: "Go")), .quotas(Quotas(windows: go.windows))]
        }
        for observation in observations { observation.apply(to: &account.groups, at: now.addingTimeInterval(-90)) }
        if account.provider == "openai" {
            GroupObservation.resetDetails(try OpenAIUsage.decodeCredits(fixture("openai-credits"))).apply(to: &account.groups, at: now.addingTimeInterval(-90))
            account.groups.selectResetSummary()
        }
        if var quotas = account.groups.quotas.data {
            for i in quotas.windows.indices {
                quotas.windows[i].resetAt = now.addingTimeInterval(i == 0 ? 7200 : 259200)
                quotas.windows[i].derive(at: now, groupStale: index == 2)
            }
            account.groups.quotas.data = quotas
        }
        account.derivePresentation()
        return account
    }
    runtime.snapshot = snapshot
    runtime.activity = try Wire.decoder().decode(ActivityResponse.self, from: fixture("activity"))
    runtime.activity?.activity.stale = true
    runtime.activityRange = .last30days
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    try Wire.encoder().encode(snapshot).write(to: URL(fileURLWithPath: output).appendingPathComponent("accounts.json"))
    func capture<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String, dark: Bool) throws {
        let host = NSHostingView(rootView: view.background(dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color(red: 0.96, green: 0.96, blue: 0.97)).environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        try #require(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
        if name.contains("pins") { #expect(host.fittingSize.width <= width) }
    }
    for dark in [false, true] {
        let suffix = dark ? "dark" : "light"
        try capture(Dashboard(runtime: runtime), width: 360, height: 650, name: "native-360-\(suffix)", dark: dark)
        try capture(RecordedActivity(runtime: runtime).padding(12), width: 360, height: 640, name: "native-activity-\(suffix)", dark: dark)
        let previousActivity = runtime.activity
        runtime.activity?.activity.data = try Wire.decoder().decode(ActivityData.self, from: fixture("activity-pricing"))
        runtime.activityRange = .today
        try capture(RecordedActivity(runtime: runtime).padding(12), width: 360, height: 1100, name: "native-pricing-\(suffix)", dark: dark)
        runtime.activity = previousActivity
        runtime.activityRange = .last30days
        for account in snapshot.accounts.prefix(4) {
            try capture(AccountCard(account: account, runtime: runtime), width: 336, height: 460, name: "native-\(account.provider)-\(suffix)", dark: dark)
        }
        try capture(HStack(spacing: 14) { Spacer(); MenuPins(runtime: runtime); Text("Mon Sep 7 16:00").font(.system(size: 12)) }.padding(.horizontal, 12), width: 1440, height: 24, name: "native-14-pins-\(suffix)", dark: dark)
        try capture(AccountDetails(account: snapshot.accounts[0]).padding(12), width: 336, height: 1800, name: "native-details-\(suffix)", dark: dark)
        let resetAccount = snapshot.accounts[1]
        let credit = try #require(resetAccount.groups.resetDetails.data?.credits.first)
        try capture(OpenAICreditDetails(account: resetAccount, runtime: runtime, expanded: true, confirming: credit.id).padding(12), width: 360, height: 1400, name: "native-reset-confirm-\(suffix)", dark: dark)
        var operation = try Wire.decoder().decode([Redemption].self, from: fixture("redemptions"))[1]
        operation.accountId = resetAccount.id; operation.accountName = resetAccount.name
        runtime.resetOperations[resetAccount.id] = operation
        var unavailable = resetAccount
        unavailable.groups.resetDetails.data = nil; unavailable.groups.resetSummary.data = nil
        try capture(AccountCard(account: unavailable, runtime: runtime, resetExplanation: true).padding(12), width: 360, height: 650, name: "native-reset-unknown-\(suffix)", dark: dark)
        runtime.resetOperations = [:]
    }
    for index in snapshot.accounts.indices { snapshot.accounts[index].pinned = false; snapshot.accounts[index].pinOrder = nil }
    runtime.snapshot = snapshot
    try capture(Dashboard(runtime: runtime), width: 360, height: 650, name: "native-unpinned", dark: false)
    let fallback = NSHostingView(rootView: MenuPins(runtime: runtime))
    #expect(fallback.fittingSize.width < 50)
    snapshot.accounts = []
    runtime.snapshot = snapshot
    try capture(Dashboard(runtime: runtime), width: 360, height: 650, name: "native-empty", dark: true)
}

@Test func cardsAndPinsSelectDistinctDurationsWithoutHidingUnknowns() async throws {
    let now = Date()
    func window(_ id: String, duration: Double?, used: Double?, scope: String = "account", cadence: String = "rolling") -> QuotaWindow {
        var result = QuotaWindow(id: id, label: id, scope: scope, cadence: cadence, durationSeconds: duration, durationSource: "provider", usedPercent: used, resetAt: now.addingTimeInterval(1800))
        result.derive(at: now, groupStale: false)
        return result
    }
    var account = Account(id: "fixture", name: "Fixture")
    let windows = [window("week", duration: 604800, used: 12), window("b", duration: 18000, used: 80),
                   window("a", duration: 18000, used: 80), window("fable", duration: 600, used: 99, scope: "model"),
                   window("month", duration: 1000, used: 99, cadence: "monthly"), window("unknown", duration: nil, used: 25)]
    account.groups.quotas.succeed(Quotas(windows: windows), at: now)
    account.derivePresentation()
    #expect(account.pin.lines.map(\.windowId) == ["a", "week"])
    #expect(account.pin.lines.map(\.remainingPercent) == [20, 88])
    #expect(account.overviewWindows.last?.id == "unknown")
    #expect(account.overviewWindows.filter { $0.durationSeconds == 18000 }.map(\.id) == ["a", "b"])
    account.groups.quotas.data?.windows.append(window("missing", duration: 18000, used: nil))
    account.derivePresentation()
    #expect(account.pin.lines.first?.windowId == "missing")
    #expect(account.pin.lines.first?.remainingPercent == nil)
    account.groups.quotas.data?.windows[0].stale = true
    account.derivePresentation()
    #expect(account.pin.warning)
    #expect(account.pin.lines.last?.remainingPercent == 88)
    account.groups.quotas.succeed(Quotas(windows: [windows[4], windows[5]]), at: now)
    account.derivePresentation()
    #expect(account.pin.lines.isEmpty)
    #expect(account.overviewWindows.last?.remainingPercent == 75)
    account.groups.quotas.observedAt = nil
    account.derivePresentation()
    #expect(account.pin.lines.isEmpty)
    let owner = TallyOwner(clock: { now }, inventory: {
        InventoryRead(databaseIdentity: "pin-fixture", credentials: [StoredCredential(storedID: "pin", name: "Pin", key: "synthetic")])
    }, collect: { _ in GoObservation(windows: windows) })
    try await owner.refresh(); await owner.waitForCollection()
    let shared = try #require(await owner.snapshot().accounts.first)
    #expect(shared.pin.lines.map(\.windowId) == ["a", "week"])
    #expect(shared.overviewWindows.last?.id == "unknown")
    await owner.shutdown()
}

@Test func grokCompatibleOmissionActualPeriodAndCreditUnits() throws {
    var groups = AccountGroups()
    for observation in try GrokUsage.decode(fixture("grok-billing")) { observation.apply(to: &groups, at: Date()) }
    let window = try #require(groups.quotas.data?.windows.first)
    #expect(window.usedPercent == 0)
    #expect(window.durationSeconds == 604800)
    #expect(window.durationSource == "provider")
    #expect(window.resetAt == (try Date("2030-09-12T13:45:37.894507Z", strategy: .iso8601)))
    let expected = try Wire.decoder().decode(ExtraUsage.self, from: fixture("grok-extra"))
    #expect(try Wire.encoder().encode(groups.extraUsage.data) == Wire.encoder().encode(expected))
    #expect(try GrokUsage.decodePlan(Data(#"{"default_model":"grok-4.6"}"#.utf8)) == nil)
    #expect(try GrokUsage.decodePlan(Data(#"{"subscription_tier_display":" SuperGrok "}"#.utf8))?.name == "SuperGrok")
    #expect(throws: Fault.self) { try GrokUsage.decodePlan(Data(#"{"subscription_tier_display":42}"#.utf8)) }
}

@Test func grokRejectsMalformedPresentPercentAndKeepsUnknownPAYG() throws {
    let source = try String(decoding: fixture("grok-billing"), as: UTF8.self)
    for value in ["null", "true", #""12""#, #""bad""#, "{}"] {
        let json = source.replacingOccurrences(of: "\"config\": {", with: "\"config\": {\"creditUsagePercent\":\(value),")
        #expect(throws: Fault.self) { try GrokUsage.decode(Data(json.utf8)) }
    }
    for json in ["{}", #"{"config":{}}"#, source.replacingOccurrences(of: "2030-09-12", with: "2030-09-01")] {
        #expect(throws: Fault.self) { try GrokUsage.decode(Data(json.utf8)) }
    }
    func read(_ json: String) throws -> AccountGroups {
        var groups = AccountGroups()
        for observation in try GrokUsage.decode(Data(json.utf8)) { observation.apply(to: &groups, at: Date()) }
        return groups
    }
    #expect(try read(source.replacingOccurrences(of: "TYPE_WEEKLY", with: "TYPE_MONTHLY")).quotas.data?.windows.isEmpty == true)
    #expect(try read(source.replacingOccurrences(of: "2030-09-05", with: "2030-09-06")).quotas.data?.windows.first?.durationSeconds == 518400)
    #expect(try read(source.replacingOccurrences(of: "2500", with: "0")).extraUsage.data?.presentation == "off")
    #expect(try read(source.replacingOccurrences(of: "{\"val\":2500}", with: "{}")).extraUsage.data?.enabled == nil)
    #expect(try read(source.replacingOccurrences(of: "{\"val\":125.5}", with: "{}")).extraUsage.data?.presentation == "unavailable")
    #expect(try read(source.replacingOccurrences(of: "125.5", with: "0")).extraUsage.data?.remainingPercent == 100)
    #expect(try read(source.replacingOccurrences(of: "125.5", with: "3000")).extraUsage.data?.remainingPercent == 0)
    #expect(throws: Fault.self) { try read(source.replacingOccurrences(of: "125.5", with: "-1")) }
    var extra = try Wire.decoder().decode(ExtraUsage.self, from: fixture("grok-extra"))
    extra.limit = nil; extra.derive()
    #expect(extra.presentation == "used_only" && extra.remaining == nil)
    extra.limit = Money(amount: "2500", currency: "USD", source: Money.Source(amount: "2500", unit: "USD")); extra.derive()
    #expect(extra.presentation == "used_only")
}

private final class GrokProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.httpMethod == "GET" && request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer stored-grok")
        #expect(request.value(forHTTPHeaderField: "X-XAI-Token-Auth") == "xai-grok-cli")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect([GrokUsage.endpoint, GrokUsage.settingsEndpoint].contains(request.url))
        let settings = request.url == GrokUsage.settingsEndpoint
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: settings ? 401 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: settings ? Data("private upstream error".utf8) : (try! fixture("grok-billing")))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func grokOptionalSettingsFailurePreservesBillingAndPin() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [GrokProtocol.self]
    let client = GrokUsage(session: URLSession(configuration: configuration))
    let owner = TallyOwner(clock: { try! Date("2030-09-07T00:00:00Z", strategy: .iso8601) }, inventory: {
        InventoryRead(databaseIdentity: "grok-db", credentials: [StoredCredential(storedID: "grok", name: "Grok", key: "stored-grok", provider: "xai")])
    }, collections: { client.jobs(access: $0.key) }, collect: { _ in throw Fault("unexpected", "No Go request expected") })
    try await owner.refresh(); await owner.waitForCollection()
    let account = try #require(await owner.snapshot().accounts.first)
    #expect(account.groups.plan.error?.code == "provider_unavailable")
    #expect(account.groups.plan.error?.message == "Grok request failed (HTTP 401).")
    #expect(account.groups.plan.data == nil)
    #expect(!account.groups.quotas.stale && !account.groups.extraUsage.stale)
    #expect(account.groups.extraUsage.data?.presentation == "bounded")
    #expect(account.pin.lines.first?.remainingPercent == 100)
    #expect(!String(decoding: try Wire.encoder().encode(account), as: UTF8.self).contains("private upstream"))
    await owner.shutdown()
}

@Test func openAIMapsActualDurationsHiddenScopesAndCreditProvenance() throws {
    struct Expected: Decodable { var balances: Balances; var details: ResetDetails; var quotas: Quotas }
    let expected = try Wire.decoder().decode(Expected.self, from: fixture("openai-readings"))
    var groups = AccountGroups()
    let now = Date(timeIntervalSince1970: 1_915_031_000)
    for observation in try OpenAIUsage.decodeUsage(fixture("openai-usage"), at: now) { observation.apply(to: &groups, at: now) }
    let windows = try #require(groups.quotas.data?.windows)
    #expect(windows.map(\.durationSeconds) == [7200, 604800, nil])
    #expect(windows.filter(\.displayInOverview).map(\.label) == ["Weekly"])
    #expect(windows[0].resetAt == now.addingTimeInterval(3600))
    #expect(windows[0].modelId == "spark-model")
    #expect(groups.plan.data?.name == "Business Premium")
    #expect(groups.resetSummary.data?.availableCount == 3)
    #expect(groups.resetSummary.data?.applicableAvailableCount == 0)
    #expect(try Wire.encoder().encode(groups.quotas.data) == Wire.encoder().encode(expected.quotas))
    #expect(try Wire.encoder().encode(groups.balances.data) == Wire.encoder().encode(expected.balances))
    #expect(try Wire.encoder().encode(OpenAIUsage.decodeCredits(fixture("openai-credits"))) == Wire.encoder().encode(expected.details))
}

@Test func openAISummarySelectsWholeIndependentObservations() throws {
    var groups = AccountGroups()
    let start = Date(timeIntervalSince1970: 1000)
    groups.resetSummary.succeed(ResetSummary(availableCount: 3, applicableAvailableCount: 0, source: "usage"), at: start)
    groups.resetDetails.succeed(try OpenAIUsage.decodeCredits(fixture("openai-credits")), at: start.addingTimeInterval(1))
    var view = groups
    view.selectResetSummary()
    #expect(view.resetSummary.data?.source == "credit_details")
    #expect(view.resetSummary.data?.availableCount == 2)
    #expect(view.resetSummary.data?.applicableAvailableCount == nil)
    #expect(view.resetSummary.observedAt == groups.resetDetails.observedAt)
    groups.resetDetails.fail(Fault("provider_unavailable", "List failed"), at: start.addingTimeInterval(120))
    groups.resetSummary.succeed(ResetSummary(availableCount: 0, source: "usage"), at: start.addingTimeInterval(121))
    view = groups; view.selectResetSummary()
    #expect(view.resetSummary.data?.availableCount == 0)
    #expect(view.resetSummary.data?.source == "usage")
    #expect(!view.resetSummary.stale)
    #expect(view.resetDetails.stale)
    #expect(view.resetDetails.observedAt == start.addingTimeInterval(1))
    groups.resetSummary.fail(Fault("provider_unavailable", "Usage failed"), at: start.addingTimeInterval(240))
    groups.resetDetails.succeed(try OpenAIUsage.decodeCredits(Data(#"{"available_count":null,"credits":[]}"#.utf8)), at: start.addingTimeInterval(241))
    view = groups; view.selectResetSummary()
    #expect(view.resetSummary.data?.availableCount == nil)
    #expect(view.resetSummary.data?.source == "credit_details")
    #expect(!view.resetSummary.stale)
}

@Test func openAICreditsPreserveAbsenceUnlimitedAndRejectMalformed() throws {
    func balance(_ json: String) throws -> Balance? {
        var groups = AccountGroups()
        for observation in try OpenAIUsage.decodeUsage(Data(json.utf8), at: Date()) { observation.apply(to: &groups, at: Date()) }
        return groups.balances.data?.items.first
    }
    #expect(try balance(#"{"credits":null}"#) == nil)
    #expect(try balance(#"{"credits":{"unlimited":true}}"#)?.unlimited == true)
    #expect(try balance(#"{"credits":{"unlimited":true}}"#)?.quantity == nil)
    #expect(try balance(#"{"credits":{"has_credits":false}}"#)?.quantity == "0")
    #expect(try balance(#"{"credits":{}}"#)?.quantity == nil)
    for json in ["{}", #"{"credits":{"balance":"bad"}}"#, #"{"credits":{"balance":"12bad"}}"#, #"{"rate_limit":{"primary_window":{"used_percent":"bad"}}}"#] {
        #expect(throws: Fault.self) { try balance(json) }
    }
    #expect(throws: Fault.self) { try OpenAIUsage.decodeCredits(Data(#"{"credits":null}"#.utf8)) }
    #expect(throws: Fault.self) { try OpenAIUsage.decodeCredits(Data(#"{"available_count":-1,"credits":[]}"#.utf8)) }
    for expiry in [#""bad""#, "42", "{}"] {
        let details = try OpenAIUsage.decodeCredits(Data("{\"credits\":[{\"id\":\"unknown\",\"expires_at\":\(expiry)}]}".utf8))
        #expect(details.credits[0].expiry.kind == "unknown")
        #expect(details.credits[0].available == nil)
    }
}

private final class OpenAIProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer shared")
        let workspace = request.value(forHTTPHeaderField: "ChatGPT-Account-Id")
        #expect(["personal", "work"].contains(workspace))
        #expect([OpenAIUsage.endpoint, OpenAIUsage.creditsEndpoint].contains(request.url))
        let json = request.url == OpenAIUsage.creditsEndpoint ? "{\"available_count\":\(workspace == "work" ? 0 : 2),\"credits\":[]}" : "{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(workspace == "work" ? 100 : 20),\"limit_window_seconds\":604800}}}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func openAIWorkspacesNeverShareUsageOrDetails() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [OpenAIProtocol.self]
    let client = OpenAIUsage(session: URLSession(configuration: config))
    let owner = TallyOwner(clock: { Date() }, inventory: {
        InventoryRead(databaseIdentity: "openai-db", credentials: [
            StoredCredential(storedID: "p", name: "Personal", key: "shared", provider: "openai", workspace: "personal"),
            StoredCredential(storedID: "w", name: "Work", key: "shared", provider: "openai", workspace: "work")
        ])
    }, collections: { client.jobs(access: $0.key, workspace: $0.workspace) }, collect: { _ in throw Fault("unexpected", "Go is not used") })
    try await owner.refresh(); await owner.waitForCollection()
    let accounts = await owner.snapshot().accounts
    #expect(accounts.count == 2)
    #expect(accounts.map { $0.groups.quotas.data?.windows.first?.usedPercent } == [20, 100])
    #expect(accounts.map { $0.groups.resetSummary.data?.availableCount } == [2, 0])
    #expect(accounts.allSatisfy { $0.groups.resetSummary.data?.source == "credit_details" })
    for job in client.jobs(access: "shared", workspace: nil) {
        do { _ = try await job.run(); Issue.record("Missing workspace sent a request") }
        catch let fault as Fault { #expect(fault.code == "credentials_unavailable") }
    }
    await owner.shutdown()
}

@Test func decodesSharedWireFixture() throws {
    let refresh = try Wire.decoder().decode(RefreshResponse.self, from: fixture("refresh"))
    #expect(refresh.accounts.map { $0.schedule.state } == ["started", "joined", "deferred", "blocked"])
    #expect(refresh.accounts[2].schedule.nextAttemptAt == refresh.accounts[2].schedule.reason?.retryAt)
    #expect(refresh.activity.state == "started")
    let response = try Wire.decoder().decode(AccountsResponse.self, from: fixture("accounts"))
    #expect(response.accounts[0].pin.lines.count == 2)
    #expect(response.accounts[0].groups.quotas.data?.windows[1].remainingPercent == nil)
    #expect(response.accounts[0].groups.quotas.data?.windows[2].usedPercent == 0)
    #expect(response.accounts[0].groups.quotas.stale)
    #expect(response.accounts[0].groups.quotas.error?.code == "provider_unavailable")
}

@Test func mapsGoWithoutInventingTiming() throws {
    let valid = try GoUsage.decode(fixture("go-valid"))
    #expect(valid.windows.map(\.durationSeconds) == [18_000, 604_800, nil])
    #expect(valid.windows[0].usedPercent == 12.5)
    #expect(valid.windows[0].resetAt != nil)
    #expect(try GoUsage.decode(fixture("go-absent")).windows.isEmpty)
    #expect(throws: Fault.self) { try GoUsage.decode(fixture("go-malformed")) }
    #expect(throws: Fault.self) { try GoUsage.decode(Data(#"{"usage":{"rolling":{"status":"error","percent":10}}}"#.utf8)) }
    var unknown = try GoUsage.decode(fixture("go-unknown")).windows
    for index in unknown.indices { unknown[index].derive(at: Date(), groupStale: false) }
    #expect(unknown[0].remainingPercent == 100)
    #expect(unknown[0].resetState == "unknown")
    #expect(unknown[1].remainingPercent == nil)
    #expect(unknown[2].durationSeconds == nil)
}

@Test func anthropicNormalizesStructuredMetersAndExactMoney() throws {
    var groups = AccountGroups()
    for observation in try AnthropicUsage.decode(fixture("anthropic-usage")) { observation.apply(to: &groups, at: Date()) }
    let windows = try #require(groups.quotas.data?.windows)
    let expectedQuotas = try Wire.decoder().decode(Quotas.self, from: fixture("anthropic-quotas"))
    #expect(try Wire.encoder().encode(groups.quotas.data) == Wire.encoder().encode(expectedQuotas))
    #expect(windows.map(\.id) == ["session", "weekly_all", "weekly_scoped:fable", "weekly_scoped:sonnet", "daily"])
    #expect(windows.map(\.usedPercent) == [20, 25, 40, 7, nil])
    #expect(windows.filter(\.displayInOverview).map(\.label) == ["5-hour", "Weekly", "Fable", "daily"])
    #expect(windows[2].scope == "model")
    #expect(windows[2].modelId == nil)
    #expect(windows[2].scopeNote?.contains("up to half") == true)
    #expect(windows.last?.durationSeconds == nil)
    #expect(groups.plan.data == nil)
    #expect(groups.plan.observedAt == nil)
    let expected = try Wire.decoder().decode(ExtraUsage.self, from: fixture("anthropic-extra"))
    #expect(try Wire.encoder().encode(groups.extraUsage.data) == Wire.encoder().encode(expected))
    #expect(try AnthropicUsage.decodePlan(Data(#"{"organization":{"organization_type":"claude_team","rate_limit_tier":"default_claude_max_5x"}}"#.utf8))?.name == "Team")
    #expect(try AnthropicUsage.decodePlan(Data(#"{"organization":{"rate_limit_tier":"default_claude_max_5x"}}"#.utf8)) == nil)
    #expect(try AnthropicUsage.decodePlan(Data(#"{"organization":{}}"#.utf8)) == nil)
    #expect(throws: Fault.self) { try AnthropicUsage.decodePlan(Data(#"{"organization":{"organization_type":42}}"#.utf8)) }
}

@Test func anthropicExtraUsageStatesAndMalformedResponses() throws {
    func extra(_ json: String) throws -> ExtraUsage? {
        var groups = AccountGroups()
        for observation in try AnthropicUsage.decode(Data(json.utf8)) { observation.apply(to: &groups, at: Date()) }
        return groups.extraUsage.data
    }
    #expect(try extra(#"{"extra_usage":null}"#) == nil)
    #expect(try extra(#"{"spend":{"enabled":false}}"#)?.presentation == "off")
    #expect(try extra(#"{"spend":{"enabled":true,"used":null}}"#)?.presentation == "unavailable")
    #expect(try extra(#"{"spend":{"used":{"amount_minor":0,"currency":"USD","exponent":2}}}"#)?.presentation == "unavailable")
    for limit in ["null", #"{"amount_minor":0,"currency":"USD","exponent":2}"#, #"{"amount_minor":-1,"currency":"USD","exponent":2}"#, #"{"amount_minor":100,"currency":"EUR","exponent":2}"#] {
        let result = try extra("{\"spend\":{\"enabled\":true,\"used\":{\"amount_minor\":0,\"currency\":\"USD\",\"exponent\":2},\"limit\":\(limit)}}")
        #expect(result?.presentation == "used_only")
        #expect(result?.used?.amount == "0")
        #expect(result?.remainingPercent == nil)
    }
    let legacy = try extra(#"{"extra_usage":{"is_enabled":true,"used_credits":123.45,"monthly_limit":200}}"#)
    #expect(legacy?.used?.amount == "1.2345")
    #expect(legacy?.remaining?.amount == "0.7655")
    #expect(legacy?.periodLabel == "Monthly")
    #expect(try extra(#"{"extra_usage":{"is_enabled":false,"used_credits":0,"monthly_limit":0}}"#)?.presentation == "off")
    for json in ["{}", "[]", #"{"error":"bad"}"#, #"{"five_hour":{"utilization":"bad"}}"#, #"{"five_hour":{"resets_at":"bad"}}"#, #"{"spend":{"used":{"amount_minor":1,"currency":"USD","exponent":-1}}}"#, #"{"limits":"bad"}"#] {
        #expect(throws: Fault.self) { try extra(json) }
    }
}

@Test func anthropicOwnerPreservesIndependentPlanAndScopedPins() async throws {
    let owner = TallyOwner(clock: { Date(timeIntervalSince1970: 1_915_031_000) }, inventory: {
        InventoryRead(databaseIdentity: "anthropic-db", credentials: [StoredCredential(storedID: "claude", name: "Claude", key: "secret", provider: "anthropic")])
    }, collections: { _ in [
        CollectionJob(id: "usage", groups: [.quotas, .extraUsage, .balances, .resetSummary, .resetDetails]) { try AnthropicUsage.decode(fixture("anthropic-usage")) },
        CollectionJob(id: "profile", groups: [.plan]) { throw Fault("provider_unavailable", "Profile failed.") }
    ] }, collect: { _ in throw Fault("unexpected", "Go is not used.") })
    try await owner.refresh()
    await owner.waitForCollection()
    let account = try #require(await owner.snapshot().accounts.first)
    #expect(account.groups.plan.stale)
    #expect(account.groups.plan.error?.code == "provider_unavailable")
    #expect(!account.groups.quotas.stale)
    #expect(!account.groups.extraUsage.stale)
    #expect(account.pin.lines.map(\.windowId) == ["session", "weekly_all"])
    #expect(account.groups.quotas.data?.windows[2].remainingPercent == 60)
    await owner.shutdown()
}

private final class AnthropicProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "claude-code/2.1.69")
        let token = request.value(forHTTPHeaderField: "Authorization")
        if token == "Bearer network" { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let status = ["Bearer rejected": 401, "Bearer cooldown": 429, "Bearer server": 500, "Bearer overloaded": 529][token ?? ""] ?? 200
        let data: Data
        if token == "Bearer malformed" { data = Data("not json".utf8) }
        else if request.url == AnthropicUsage.profileEndpoint { data = Data(#"{"organization":{"organization_type":"claude_pro"}}"#.utf8) }
        else { data = (try? fixture("anthropic-usage")) ?? Data() }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "600"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func anthropicHTTPUsesStoredBearerAndSanitizesFailures() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AnthropicProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let collector = AnthropicUsage(session: session)
    #expect(try await collector.collect(access: "valid").count == 5)
    var groups = AccountGroups()
    for observation in try await collector.planJob(access: "valid").run() { observation.apply(to: &groups, at: Date()) }
    #expect(groups.plan.data?.name == "Pro")
    for (token, code) in [("rejected", "credentials_rejected"), ("cooldown", "provider_unavailable"), ("server", "provider_unavailable"), ("overloaded", "provider_unavailable"), ("malformed", "provider_response_invalid"), ("network", "provider_unavailable")] {
        for job in [collector.job(access: token), collector.planJob(access: token)] {
            do {
                _ = try await job.run()
                Issue.record("Expected a sanitized provider failure.")
            } catch let fault as Fault {
                #expect(fault.code == code)
                #expect(fault.message.contains("Check the Account in OpenCode") == (token == "rejected"))
                if token == "cooldown" { #expect(fault.retryAt?.timeIntervalSinceNow ?? 0 > 590) }
                #expect(!fault.message.contains("Bearer"))
            }
        }
    }
}

@Test func discoversReadOnlyGoInventory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("opencode.db").path
    var db: OpaquePointer?
    #expect(sqlite3_open(path, &db) == SQLITE_OK)
    let sql = """
    CREATE TABLE credential (id TEXT, integration_id TEXT, label TEXT, value TEXT, active INTEGER, time_created INTEGER, additional TEXT);
    INSERT INTO credential VALUES ('zen', 'opencode', 'Zen first', '{"type":"key","key":"key-a"}', 1, 0, NULL);
    INSERT INTO credential VALUES ('a', 'opencode-go', 'Go Personal', '{"type":"key","key":"key-a"}', 0, 1, NULL);
    INSERT INTO credential VALUES ('b', 'opencode-go', 'WORK', '{"type":"key","key":"key-b"}', 1, 2, NULL);
    INSERT INTO credential VALUES ('c', 'opencode-go', 'Duplicate', '{"type":"key","key":"key-a"}', 1, 3, NULL);
    INSERT INTO credential VALUES ('d', 'opencode-go', 'Unsupported', '{"type":"oauth"}', 0, 4, NULL);
    INSERT INTO credential VALUES ('invalid-e', 'opencode-go', 'Whitespace key', '{"type":"key","key":"bad key"}', 0, 5, NULL);
    INSERT INTO credential VALUES ('invalid-f', 'opencode-go', 'Empty key', '{"type":"key","key":""}', 0, 6, NULL);
    INSERT INTO credential VALUES ('invalid-g', 'opencode-go', 'Missing key', '{"type":"key"}', 0, 7, NULL);
    INSERT INTO credential VALUES ('e', 'anthropic', 'Claude', '{"type":"oauth","methodID":"claude-subscription","access":"claude-a","refresh":"claude-r","expires":0,"metadata":{"accountID":42},"key":42}', 0, 5, NULL);
    INSERT INTO credential VALUES ('f', 'openai', 'Workspace A', '{"type":"oauth","methodID":"chatgpt-browser","access":"shared","refresh":"r","expires":0,"metadata":{"accountID":"workspace-a","addition":true}}', 0, 6, NULL);
    INSERT INTO credential VALUES ('g', 'openai', 'Workspace B', '{"type":"oauth","methodID":"chatgpt-browser","access":"shared","refresh":"r","expires":0,"metadata":{"accountID":"workspace-b"}}', 1, 7, NULL);
    INSERT INTO credential VALUES ('h', 'openai', 'Duplicate workspace', '{"type":"oauth","methodID":"chatgpt-headless","access":"other","refresh":"other-r","expires":0,"metadata":{"accountID":"workspace-a"}}', 1, 8, NULL);
    INSERT INTO credential VALUES ('i', 'xai', 'Grok', '{"type":"oauth","methodID":"device","access":"grok-a","refresh":"grok-r","expires":0}', 0, 9, NULL);
    INSERT INTO credential VALUES ('j', 'anthropic', 'API', '{"type":"key","key":"api-key"}', 1, 10, NULL);
    INSERT INTO credential VALUES ('k', 'openai', 'Unsupported method', '{"type":"oauth","methodID":"other"}', 1, 11, NULL);
    INSERT INTO credential VALUES ('l', 'mcp', 'MCP', 'invalid', 1, 12, NULL);
    """
    #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let before = try Data(contentsOf: URL(fileURLWithPath: path))
    let credentials = try OpenCodeInventory(path: path).read().credentials
    #expect(credentials.map(\.name) == ["Go Personal", "WORK", "Claude", "Workspace A", "Workspace B", "Grok"])
    #expect(credentials.prefix(2).map(\.key) == ["key-a", "key-b"])
    #expect(credentials[2].expiresAt == Date(timeIntervalSince1970: 0))
    #expect(credentials[0].expiresAt == nil)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
    #expect(throws: Fault.self) { try OpenCodeInventory(path: path + "-missing").read() }
    #expect(!FileManager.default.fileExists(atPath: path + "-missing"))
    #expect(OpenCodeInventory.defaultPath(environment: ["XDG_DATA_HOME": "/data", "OPENCODE_DB": "custom.db"], home: "/home") == "/data/opencode/custom.db")
    #expect(OpenCodeInventory.defaultPath(environment: ["OPENCODE_DB": "/custom.db"], home: "/home") == "/custom.db")
}

private final class Scenario: @unchecked Sendable {
    private let lock = NSLock()
    private var currentTime = Date(timeIntervalSince1970: 1_915_017_600)
    private var failed = false
    private var calls = 0
    func now() -> Date { lock.withLock { currentTime } }
    func advanceAndFail() { lock.withLock { currentTime += 20; failed = true } }
    func fetch() throws -> GoObservation {
        let failed = lock.withLock { calls += 1; return self.failed }
        if failed { throw Fault("provider_unavailable", "Sanitized provider failure.") }
        return try GoUsage.decode(fixture("go-valid"))
    }
    func count() -> Int { lock.withLock { calls } }
}

@Test func cachedReadsFailureAndRefreshContract() async throws {
    let scenario = Scenario()
    let owner = TallyOwner(clock: { scenario.now() }, inventory: {
        InventoryRead(databaseIdentity: "test-db", credentials: [StoredCredential(storedID: "cred-secret", name: "Fixture Go", key: "test-secret")])
    }, collect: { _ in try scenario.fetch() })
    #expect(await owner.snapshot().accounts.isEmpty)
    #expect(scenario.count() == 0)
    let refresh = try await owner.refresh()
    #expect(refresh.accounts.first?.schedule.state == "started")
    await owner.waitForCollection()
    let first = await owner.snapshot()
    #expect(first.accounts[0].groups.quotas.data?.windows[0].remainingPercent == 87.5)
    #expect(first.accounts[0].groups.plan.data?.name == "Go")
    #expect(first.accounts[0].groups.extraUsage.observedAt != nil)
    #expect(first.accounts[0].groups.extraUsage.data == nil)
    let wire = try Wire.encoder().encode(first)
    #expect(!String(decoding: wire, as: UTF8.self).contains("test-secret"))
    #expect(!String(decoding: wire, as: UTF8.self).contains("cred-secret"))
    #expect(try Wire.decoder().decode(AccountsResponse.self, from: wire).accounts.count == 1)
    #expect(try Wire.decoder().decode(AccountsResponse.self, from: wire).accounts[0].groups.quotas.data?.windows[0].resetAt == first.accounts[0].groups.quotas.data?.windows[0].resetAt)
    let object = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
    let account = try #require((object["accounts"] as? [[String: Any]])?.first)
    let groups = try #require(account["groups"] as? [String: [String: Any]])
    #expect(groups["extraUsage"]?["data"] is NSNull)
    #expect(groups["quotas"]?["error"] is NSNull)
    _ = await owner.snapshot(); _ = try await owner.account(id: first.accounts[0].id)
    #expect(scenario.count() == 1)
    #expect(try await owner.refresh().accounts[0].schedule.state == "deferred")
    scenario.advanceAndFail()
    try await owner.refresh()
    await owner.waitForCollection()
    let failed = await owner.snapshot().accounts[0].groups.quotas
    #expect(failed.stale)
    #expect(failed.observedAt == first.accounts[0].groups.quotas.observedAt)
    #expect(failed.data?.windows[0].remainingPercent == 87.5)
    #expect(failed.error?.code == "provider_unavailable")
    await owner.shutdown()
    #expect(await owner.snapshot().status.owner == "shutting_down")
}

@Test func resetPassageDoesNotReplenish() throws {
    var window = try GoUsage.decode(fixture("go-valid")).windows[0]
    window.derive(at: window.resetAt!.addingTimeInterval(1), groupStale: false)
    #expect(window.stale)
    #expect(window.resetState == "passed")
    #expect(window.remainingPercent == 87.5)
    #expect(window.pacing == nil)
}

private final class InventoryScenario: @unchecked Sendable {
    private let lock = NSLock()
    private var value = InventoryRead(databaseIdentity: "database-a", credentials: [])
    private var failure = false
    func read() throws -> InventoryRead {
        try lock.withLock {
            if failure { throw Fault("inventory_schema_incompatible", "Synthetic schema failure.") }
            return value
        }
    }
    func set(_ credentials: [StoredCredential], database: String = "database-a") {
        lock.withLock { value = InventoryRead(databaseIdentity: database, credentials: credentials); failure = false }
    }
    func fail() { lock.withLock { failure = true } }
}

@Test func identityPreferencesSurviveRestartRemovalAndNamespaceSwitches() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = directory.appendingPathComponent("accounts.json")
    let scenario = InventoryScenario()
    let owner = TallyOwner(clock: { Date() }, storageURL: storage, inventory: { try scenario.read() }, collect: { _ in try GoUsage.decode(fixture("go-valid")) })
    scenario.fail()
    await #expect(throws: Fault.self) { try await owner.refresh() }
    scenario.set([])
    try await owner.refresh()
    let entries = (0..<8).map { StoredCredential(storedID: "row-\($0)", name: "Account \($0)", key: "secret-\($0)") }
    scenario.set(entries.reversed())
    try await owner.refresh()
    await owner.waitForCollection()
    let first = await owner.snapshot()
    #expect(first.accounts.map(\.identityColorIndex) == [0, 1, 2, 3, 4, 5, 0, 1])
    #expect(first.accounts.map(\.pinOrder) == Array(0..<8).map(Optional.some))
    let pins = [first.accounts[4].id, first.accounts[0].id]
    try await owner.setPins(pins)
    var renamed = entries
    renamed[0].name = "VERBATIM Renamed"
    scenario.set(renamed + [StoredCredential(storedID: "new", name: "Later", key: "new-secret")])
    try await owner.refresh(accountIDs: [])
    let changed = await owner.snapshot()
    #expect(changed.accounts.filter(\.pinned).map(\.id) == pins)
    #expect(changed.accounts.first(where: { $0.name == "VERBATIM Renamed" })?.id == first.accounts[0].id)
    #expect(changed.accounts.first(where: { $0.name == "Later" })?.pinned == false)
    #expect(changed.accounts.first(where: { $0.name == "Later" })?.identityColorIndex == 2)
    scenario.fail()
    await #expect(throws: Fault.self) { try await owner.refresh() }
    let failed = await owner.snapshot()
    #expect(failed.accounts.count == 9)
    #expect(failed.status.inventory.stale)
    #expect(failed.accounts.allSatisfy { $0.groups.quotas.stale })
    scenario.set(entries, database: "database-b")
    try await owner.refresh(accountIDs: [])
    let other = await owner.snapshot()
    #expect(other.status.inventory.data?.namespaceId != first.status.inventory.data?.namespaceId)
    #expect(Set(other.accounts.map(\.id)).isDisjoint(with: first.accounts.map(\.id)))
    #expect(other.accounts.allSatisfy { $0.groups.quotas.data == nil && $0.pinned })
    scenario.set(renamed + [StoredCredential(storedID: "new", name: "Later", key: "new-secret")])
    try await owner.refresh(accountIDs: [])
    let returned = await owner.snapshot()
    #expect(returned.accounts.filter(\.pinned).map(\.id) == pins)
    #expect(returned.accounts[0].groups.quotas.data != nil)
    #expect(returned.accounts[0].groups.quotas.stale)
    let restarted = TallyOwner(clock: { Date() }, storageURL: storage, inventory: { try scenario.read() }, collect: { _ in throw Fault("unexpected", "No collection expected.") })
    try await restarted.refresh(accountIDs: [])
    #expect(await restarted.snapshot().accounts.map(\.id) == returned.accounts.map(\.id))
    #expect(await restarted.snapshot().accounts.filter(\.pinned).map(\.id) == pins)
    scenario.set(Array(renamed.dropFirst()))
    try await restarted.refresh(accountIDs: [])
    #expect(await restarted.snapshot().accounts.contains { $0.id == first.accounts[0].id } == false)
    scenario.set(renamed)
    try await restarted.refresh(accountIDs: [])
    let restored = try await restarted.account(id: first.accounts[0].id).account
    #expect(!restored.pinned && restored.pinOrder == nil)
    #expect(restored.identityColorIndex == 0)
    #expect(restored.groups.quotas.data == nil)
    let saved = try String(contentsOf: storage, encoding: .utf8)
    #expect(!saved.contains("secret-0") && !saved.contains("row-0"))
    try await restarted.setPins([])
    #expect(await restarted.snapshot().accounts.allSatisfy { !$0.pinned && $0.pinOrder == nil })
}

@Test func oauthContinuityAndCommandEvidenceRemainConservative() async throws {
    let scenario = InventoryScenario()
    let owner = TallyOwner(clock: { Date() }, inventory: { try scenario.read() }, collect: { _ in throw Fault("unexpected", "Only Go collects in this slice.") })
    let claude = StoredCredential(storedID: "a", name: "same", key: "access", provider: "anthropic", refresh: "refresh")
    let workspace = StoredCredential(storedID: "b", name: "Same", key: "openai-access", provider: "openai", refresh: "openai-refresh", workspace: "workspace")
    scenario.set([workspace, claude])
    try await owner.refresh()
    let first = await owner.snapshot()
    #expect(first.accounts.map(\.provider) == ["anthropic", "openai"])
    let claudeID = first.accounts[0].id
    let openaiID = first.accounts[1].id
    let evidence = try await owner.identityEvidence(accountID: openaiID)
    var refreshed = claude; refreshed.key = "new-access"
    var openai = workspace; openai.key = "new-openai-access"; openai.refresh = "new-openai-refresh"
    scenario.set([refreshed, openai])
    try await owner.refresh(accountIDs: [])
    #expect(await owner.snapshot().accounts.map(\.id) == [claudeID, openaiID])
    #expect(try await owner.identityEvidence(accountID: openaiID).relation(to: evidence) == .same)
    refreshed.key = "replacement-access"; refreshed.refresh = "replacement-refresh"
    openai.workspace = "other-workspace"
    scenario.set([refreshed, openai])
    await #expect(throws: Fault.self) { try await owner.refresh(accountIDs: [openaiID]) }
    let replacement = await owner.snapshot()
    #expect(Set(replacement.accounts.map(\.id)).isDisjoint(with: first.accounts.map(\.id)))
    #expect(replacement.accounts.allSatisfy { !$0.pinned && $0.groups.quotas.data == nil })
    #expect(openai.evidence.relation(to: evidence) == .different)
    #expect(refreshed.evidence.relation(to: claude.evidence) == .uncertain)
    var unknownWorkspace = workspace; unknownWorkspace.workspace = nil
    #expect(unknownWorkspace.evidence.relation(to: evidence) == .uncertain)
    scenario.set([workspace], database: "other-db")
    try await owner.refresh(accountIDs: [])
    let crossNamespace = try #require(await owner.snapshot().accounts.first)
    #expect(crossNamespace.id != openaiID)
    #expect(try await owner.identityEvidence(accountID: crossNamespace.id).relation(to: evidence) == .same)
}

@Test func filesystemNamespaceAndSchemaFailuresAreIndependent() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("opencode.db").path
    func create(_ path: String) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TABLE credential (id TEXT, label TEXT, value TEXT, integration_id TEXT, time_created INTEGER); INSERT INTO credential VALUES ('same-row', 'Same', '{\"type\":\"key\",\"key\":\"same-key\"}', 'opencode-go', 1); CREATE TABLE message (incompatible TEXT);", nil, nil, nil) == SQLITE_OK)
    }
    try create(path)
    let owner = TallyOwner(databasePath: path, appBuild: "test", storageURL: directory.appendingPathComponent("state.json"))
    try await owner.refresh(accountIDs: [])
    let first = await owner.snapshot()
    #expect(first.accounts.count == 1)
    let alias = directory.appendingPathComponent("alias.db").path
    try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: path)
    try await owner.setDatabasePath(alias)
    #expect(await owner.snapshot().accounts.first?.id == first.accounts.first?.id)
    let old = path + ".old"
    try FileManager.default.moveItem(atPath: path, toPath: old)
    try create(path)
    try await owner.refresh(accountIDs: [])
    #expect(await owner.snapshot().status.inventory.data?.namespaceId != first.status.inventory.data?.namespaceId)
    #expect(await owner.snapshot().accounts.first?.id != first.accounts.first?.id)
    try await owner.setDatabasePath(old)
    #expect(await owner.snapshot().accounts.first?.id == first.accounts.first?.id)
    var db: OpaquePointer?
    #expect(sqlite3_open(old, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "ALTER TABLE credential RENAME COLUMN value TO incompatible", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    await #expect(throws: Fault.self) { try await owner.refresh(accountIDs: []) }
    #expect(await owner.snapshot().accounts.first?.id == first.accounts.first?.id)
    #expect(await owner.snapshot().status.inventory.error?.code == "inventory_schema_incompatible")
    await #expect(throws: Error.self) { try await owner.setDatabasePath(path + ".missing") }
    #expect(await owner.snapshot().accounts.isEmpty)
    #expect(await owner.snapshot().status.inventory.data == nil)
}

@Test func duplicateNamesAndProviderLocalPaletteHaveStableOrder() async throws {
    let entries = providerOrder.flatMap { provider in
        (0..<7).map { index in
            StoredCredential(storedID: "\(provider)-\(index)", name: index == 0 ? "Alpha" : "alpha", key: "\(provider)-secret-\(index)", provider: provider)
        }
    }
    let scenario = InventoryScenario()
    scenario.set(entries.reversed())
    let owner = TallyOwner(clock: { Date() }, inventory: { try scenario.read() }, collect: { _ in throw Fault("unexpected", "No collection expected.") })
    try await owner.refresh(accountIDs: [])
    let first = await owner.snapshot()
    #expect(first.accounts.map(\.provider) == providerOrder.flatMap { Array(repeating: $0, count: 7) })
    for provider in providerOrder {
        let accounts = first.accounts.filter { $0.provider == provider }
        #expect(accounts.map(\.identityColorIndex) == [0, 1, 2, 3, 4, 5, 0])
        #expect(accounts.map(\.name) == ["Alpha"] + Array(repeating: "alpha", count: 6))
    }
    scenario.set(entries)
    try await owner.refresh(accountIDs: [])
    #expect(await owner.snapshot().accounts.map(\.id) == first.accounts.map(\.id))
}

@Test func preferenceWriteFailureDoesNotStopCollectionOrClaimSavedPins() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("not-a-directory")
    try Data("blocking file".utf8).write(to: file)
    let owner = TallyOwner(clock: { Date() }, storageURL: file.appendingPathComponent("state.json"), inventory: {
        InventoryRead(databaseIdentity: "db", credentials: [StoredCredential(storedID: "row", name: "Go", key: "secret")])
    }, collect: { _ in try GoUsage.decode(fixture("go-valid")) })
    try await owner.refresh()
    await owner.waitForCollection()
    #expect(await owner.snapshot().accounts.first?.groups.quotas.data != nil)
    #expect(await owner.settingsError()?.code == "settings_storage_unavailable")
    await #expect(throws: Fault.self) { try await owner.setPins([]) }
    #expect(await owner.snapshot().accounts.first?.pinned == true)
    try FileManager.default.removeItem(at: file)
    try await owner.refresh(accountIDs: [])
    #expect(await owner.settingsError() == nil)
}

@Test func inventoryRescanPreservesInFlightReadingState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("opencode.db").path
    var db: OpaquePointer?
    #expect(sqlite3_open(path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "CREATE TABLE credential (id TEXT, label TEXT, value TEXT, integration_id TEXT, time_created INTEGER); INSERT INTO credential VALUES ('row', 'Go', '{\"type\":\"key\",\"key\":\"secret\"}', 'opencode-go', 1);", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let source = OpenCodeInventory(path: path)
    let (observations, continuation) = AsyncStream<GoObservation>.makeStream()
    let owner = TallyOwner(clock: { Date() }, inventory: {
        try source.read()
    }, collect: { _ in
        for await observation in observations { return observation }
        throw Fault("unexpected", "Missing synthetic observation.")
    })
    try await owner.refresh()
    let first = await owner.snapshot().accounts[0].groups.quotas
    #expect(first.refreshing)
    try await owner.setDatabasePath(path)
    #expect(try await owner.refresh().accounts[0].schedule.state == "joined")
    let joined = await owner.snapshot().accounts[0].groups.quotas
    #expect(joined.refreshing)
    #expect(joined.lastAttemptAt == first.lastAttemptAt)
    continuation.yield(try GoUsage.decode(fixture("go-valid")))
    continuation.finish()
    await owner.waitForCollection()
    #expect(await owner.snapshot().accounts[0].groups.quotas.data != nil)
    let alias = directory.appendingPathComponent("alias.db").path
    try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: path)
    try await owner.setDatabasePath(alias)
    #expect(await owner.snapshot().accounts[0].groups.quotas.stale == false)
}

private final class SchedulingScenario: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_900_000_000)
    private var counts: [String: Int] = [:]
    private var failures: [String: Fault] = [:]
    private var entries = [StoredCredential(storedID: "a", name: "A", key: "a"), StoredCredential(storedID: "b", name: "B", key: "b")]
    func now() -> Date { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    func count(_ key: String) -> Int { lock.withLock { counts[key, default: 0] } }
    func fail(_ key: String, _ fault: Fault?) { lock.withLock { failures[key] = fault } }
    func set(_ entries: [StoredCredential]) { lock.withLock { self.entries = entries } }
    func inventory() -> InventoryRead {
        lock.withLock { counts["inventory", default: 0] += 1; return InventoryRead(databaseIdentity: "db", credentials: entries) }
    }
    func call(_ key: String) throws {
        try lock.withLock { counts[key, default: 0] += 1; if let fault = failures[key] { throw fault } }
    }
    func owner(storage: URL? = nil) -> TallyOwner {
        TallyOwner(clock: { self.now() }, storageURL: storage, inventory: { self.inventory() }, scanActivity: { _ in try self.call("activity"); return ActivityScan(databaseIdentity: "db", rows: []) }, collect: { key in
            try self.call(key)
            return GoObservation(windows: [QuotaWindow(id: "rolling", label: "5-hour", cadence: "rolling", durationSeconds: 18_000,
                                                       durationSource: "verified_mapping", usedPercent: 20, resetAt: self.now().addingTimeInterval(9_000))])
        })
    }
}

@Test func controlledCadenceWakeMinimumAndRefreshValidation() async throws {
    let scenario = SchedulingScenario()
    let owner = scenario.owner()
    await owner.tick(); await owner.waitForCollection()
    let initial = await owner.snapshot()
    #expect(scenario.count("a") == 1 && scenario.count("b") == 1 && scenario.count("activity") == 1)
    #expect(initial.accounts[0].groups.quotas.nextAttemptAt == scenario.now().addingTimeInterval(120))
    scenario.advance(119)
    await owner.tick(); await owner.waitForCollection()
    #expect(scenario.count("a") == 1 && scenario.count("inventory") == 1)
    scenario.advance(1)
    await owner.tick(); await owner.waitForCollection()
    #expect(scenario.count("a") == 2 && scenario.count("inventory") == 2)
    let id = initial.accounts[0].id
    let duplicate = try await owner.refresh(accountIDs: [id, id])
    #expect(duplicate.accounts.count == 1 && duplicate.accounts[0].schedule.state == "deferred")
    await owner.waitForCollection()
    let scans = scenario.count("activity")
    await #expect(throws: Fault.self) { try await owner.refresh(accountIDs: [id, "unknown"]) }
    #expect(scenario.count("activity") == scans)
    #expect(try await owner.refresh(accountIDs: []).accounts.isEmpty)
    await owner.waitForCollection()
    #expect(scenario.count("activity") == scans + 1 && scenario.count("a") == 2)
    scenario.advance(14)
    #expect(try await owner.refresh(accountIDs: [id]).accounts[0].schedule.state == "deferred")
    await owner.waitForCollection()
    scenario.advance(1)
    #expect(try await owner.refresh(accountIDs: [id]).accounts[0].schedule.state == "started")
    await owner.waitForCollection()
    scenario.advance(15)
    await owner.wake(); await owner.waitForCollection()
    #expect(scenario.count("a") == 4 && scenario.count("b") == 3)
    #expect(await owner.snapshot().accounts[0].groups.quotas.observedAt == scenario.now())
}

@Test func backoffRetryAfterAndRestartRetainIndependentLastGoodReadings() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let scenario = SchedulingScenario()
    let storage = directory.appendingPathComponent("readings.json")
    let owner = scenario.owner(storage: storage)
    try await owner.refresh(); await owner.waitForCollection()
    let observed = scenario.now()
    scenario.fail("a", Fault("provider_unavailable", "Synthetic failure."))
    scenario.advance(15)
    for delay: TimeInterval in [120, 240, 480, 900, 900] {
        let response = try await owner.refresh()
        #expect(response.accounts[0].schedule.state == "started")
        await owner.waitForCollection()
        let snapshot = await owner.snapshot()
        #expect(snapshot.accounts[0].groups.quotas.observedAt == observed)
        #expect(snapshot.accounts[0].groups.quotas.data?.windows[0].usedPercent == 20)
        #expect(snapshot.accounts[0].groups.quotas.nextAttemptAt == scenario.now().addingTimeInterval(delay))
        #expect(snapshot.accounts[0].groups.quotas.error?.retryAt == scenario.now().addingTimeInterval(delay))
        #expect(!snapshot.accounts[1].groups.quotas.stale)
        let activityCalls = scenario.count("activity")
        #expect(try await owner.refresh().accounts[0].schedule.state == "deferred")
        await owner.waitForCollection()
        #expect(scenario.count("activity") == activityCalls + 1)
        scenario.advance(delay)
    }
    var longer = Fault("provider_unavailable", "Rate limited.")
    longer.retryAt = scenario.now().addingTimeInterval(3_600)
    scenario.fail("a", longer)
    try await owner.refresh(); await owner.waitForCollection()
    let restarted = scenario.owner(storage: storage)
    let restored = try await restarted.refresh()
    #expect(restored.accounts[0].schedule.state == "deferred")
    #expect(restored.accounts[0].schedule.nextAttemptAt == longer.retryAt)
    #expect(await restarted.snapshot().accounts[0].groups.quotas.stale)
    #expect(await restarted.snapshot().accounts[0].groups.quotas.observedAt == observed)
    let calls = scenario.count("a")
    scenario.advance(900)
    await restarted.wake(); await restarted.waitForCollection()
    #expect(scenario.count("a") == calls)
    scenario.fail("a", nil); scenario.advance(2_700)
    await restarted.tick(); await restarted.waitForCollection()
    #expect(scenario.count("a") == calls + 1)
    #expect(await restarted.snapshot().accounts[0].groups.quotas.nextAttemptAt == scenario.now().addingTimeInterval(120))
    #expect(!String(decoding: try Data(contentsOf: storage), as: UTF8.self).contains("\"key\""))
}

@Test func tokenRotationPreservesFreshReadingsAndCancelsRefresh() async throws {
    let scenario = SchedulingScenario()
    var credential = StoredCredential(storedID: "a", name: "A", key: "old", provider: "anthropic", refresh: "continuity")
    scenario.set([credential])
    let (values, continuation) = AsyncStream<GoObservation>.makeStream()
    defer { continuation.finish() }
    let owner = TallyOwner(clock: { scenario.now() }, inventory: { scenario.inventory() }, collections: { _ in
        [.go {
            for await value in values { return value }
            throw Fault("cancelled", "Synthetic collection cancelled.")
        }]
    }, collect: { _ in throw Fault("unexpected", "Uses synthetic jobs.") })
    try await owner.refresh()
    continuation.yield(GoObservation(windows: []))
    await owner.waitForCollection()
    let first = await owner.snapshot().accounts[0]
    scenario.advance(15)
    try await owner.refresh()
    #expect(await owner.snapshot().accounts[0].groups.quotas.refreshing)
    credential.key = "rotated"
    scenario.set([credential])
    #expect(try await owner.refresh().accounts[0].schedule.state == "deferred")
    let rotated = await owner.snapshot().accounts[0]
    #expect(rotated.id == first.id)
    #expect(!rotated.groups.plan.stale && !rotated.groups.plan.refreshing)
    #expect(!rotated.groups.quotas.stale && !rotated.groups.quotas.refreshing)
    #expect(!rotated.groups.extraUsage.stale && !rotated.groups.extraUsage.refreshing)
    #expect(!rotated.groups.balances.stale && !rotated.groups.balances.refreshing)
    #expect(!rotated.groups.resetSummary.stale && !rotated.groups.resetSummary.refreshing)
    #expect(!rotated.groups.resetDetails.stale && !rotated.groups.resetDetails.refreshing)
    #expect(rotated.groups.quotas.observedAt == first.groups.quotas.observedAt)
    #expect(rotated.groups.quotas.data?.windows.isEmpty == true)
    #expect(rotated.groups.quotas.error == nil)
    await owner.shutdown()
}

@Test func rejectedAndExpiredCredentialsRequireChangedUsableTokens() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let scenario = SchedulingScenario()
    var credential = StoredCredential(storedID: "a", name: "A", key: "old", refresh: "continuity", expiresAt: scenario.now().addingTimeInterval(60))
    scenario.set([credential])
    scenario.fail("old", Fault("credentials_rejected", "Rejected."))
    let owner = scenario.owner(storage: directory.appendingPathComponent("state.json"))
    try await owner.refresh(); await owner.waitForCollection()
    let id = try #require(await owner.snapshot().accounts.first?.id)
    scenario.advance(30)
    #expect(try await owner.refresh().accounts[0].schedule.state == "blocked")
    let restarted = scenario.owner(storage: directory.appendingPathComponent("state.json"))
    #expect(try await restarted.refresh().accounts[0].schedule.state == "blocked")
    #expect(scenario.count("old") == 1)
    credential.key = "new-expired"; credential.expiresAt = scenario.now()
    scenario.set([credential])
    #expect(try await restarted.refresh().accounts[0].schedule.reason?.code == "credentials_expired")
    #expect(scenario.count("new-expired") == 0)
    credential.expiresAt = scenario.now().addingTimeInterval(600)
    scenario.set([credential])
    #expect(try await restarted.refresh().accounts[0].schedule.state == "blocked")
    credential.key = "usable"
    scenario.set([credential])
    #expect(try await restarted.refresh().accounts[0].schedule.state == "started")
    await restarted.waitForCollection()
    #expect(await restarted.snapshot().accounts[0].id == id)
    #expect(scenario.count("usable") == 1)
}

@Test func independentGroupsKeepSuccessAbsenceAttemptAndFailureSeparate() async throws {
    let scenario = SchedulingScenario()
    let (values, continuation) = AsyncStream<[GroupObservation]>.makeStream()
    let owner = TallyOwner(clock: { scenario.now() }, inventory: { scenario.inventory() }, collections: { _ in
        [CollectionJob(id: "plan", groups: [.plan]) {
            for await value in values { return value }
            throw Fault("provider_unavailable", "Optional metadata failed.")
        }, CollectionJob(id: "usage", groups: [.quotas]) {
            [.quotas(Quotas(windows: []))]
        }]
    }, collect: { _ in throw Fault("unexpected", "Uses independent jobs.") })
    scenario.set([StoredCredential(storedID: "a", name: "A", key: "a")])
    try await owner.refresh()
    let started = scenario.now()
    #expect(try await owner.refresh().accounts[0].schedule.state == "joined")
    scenario.advance(30)
    continuation.yield([.plan(Plan(name: "Example"))])
    await owner.waitForCollection()
    var groups = await owner.snapshot().accounts[0].groups
    #expect(groups.plan.lastAttemptAt == started)
    #expect(groups.plan.observedAt == scenario.now())
    #expect(groups.quotas.data?.windows.isEmpty == true)
    scenario.advance(15)
    try await owner.refresh()
    continuation.yield([.plan(nil)])
    await owner.waitForCollection()
    groups = await owner.snapshot().accounts[0].groups
    #expect(groups.plan.data == nil && groups.plan.observedAt == scenario.now() && groups.plan.error == nil)
    let lastGood = groups.plan.observedAt
    continuation.finish()
    scenario.advance(15)
    try await owner.refresh(); await owner.waitForCollection()
    groups = await owner.snapshot().accounts[0].groups
    #expect(groups.plan.stale && groups.plan.observedAt == lastGood)
    #expect(!groups.quotas.stale && groups.quotas.observedAt == scenario.now())
    scenario.advance(15)
    #expect(try await owner.refresh().accounts[0].schedule.state == "started")
    await owner.waitForCollection()
    groups = await owner.snapshot().accounts[0].groups
    #expect(groups.plan.observedAt == lastGood && !groups.quotas.stale)
}

@Test func corruptedCacheStillCollectsAndAgeDoesNotChangeObservations() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = directory.appendingPathComponent("state.json")
    try Data("{damaged".utf8).write(to: storage)
    let scenario = SchedulingScenario()
    let owner = scenario.owner(storage: storage)
    try await owner.refresh(); await owner.waitForCollection()
    let first = await owner.snapshot()
    scenario.advance(299)
    #expect(await owner.snapshot().accounts[0].groups.quotas.stale == false)
    scenario.advance(1)
    let aged = await owner.snapshot()
    #expect(aged.accounts[0].groups.quotas.stale)
    #expect(aged.accounts[0].groups.quotas.observedAt == first.accounts[0].groups.quotas.observedAt)
    #expect(aged.accounts[0].groups.quotas.data?.windows[0].pacing == nil)
    #expect(scenario.count("a") == 1)
    var cache = AccountIdentityStore(url: storage)
    let duplicate = try #require(cache.state.namespaces["db"]?.records.first)
    cache.state.namespaces["db"]?.records.append(duplicate)
    try cache.save()
    let restarted = scenario.owner(storage: storage)
    try await restarted.refresh(); await restarted.waitForCollection()
    let recovered = await restarted.snapshot()
    #expect(recovered.accounts.map(\.id) == first.accounts.map(\.id))
    #expect(recovered.accounts.allSatisfy { !$0.groups.quotas.stale })
    #expect(scenario.count("a") == 2)
}

@Test func pacingBoundariesAndRetryAfterParsing() throws {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    func window(duration: Double?, elapsed: Double, used: Double? = 20) -> QuotaWindow {
        QuotaWindow(id: "quota", label: "Quota", cadence: "other", durationSeconds: duration, durationSource: duration == nil ? "unknown" : "provider",
                    usedPercent: used, resetAt: now.addingTimeInterval((duration ?? 1_000) - elapsed))
    }
    for (duration, minimum) in [(1_000.0, 60.0), (18_000.0, 180.0)] {
        var early = window(duration: duration, elapsed: minimum - 0.001)
        early.derive(at: now, groupStale: false)
        #expect(early.pacing == nil)
        var exact = window(duration: duration, elapsed: minimum)
        exact.derive(at: now, groupStale: false)
        #expect(exact.pacing?.projectedUsedPercent == 20 * duration / minimum)
        #expect(exact.pacing!.sparePercent < 0 && exact.pacing!.runOutAt! < exact.resetAt!)
    }
    var lasts = window(duration: 1_000, elapsed: 500, used: 10)
    lasts.derive(at: now, groupStale: false)
    #expect(lasts.pacing?.projectedUsedPercent == 20 && lasts.pacing?.sparePercent == 80)
    #expect(lasts.pacing?.runOutAt == nil && lasts.pacing?.runOutReason != nil)
    for var invalid in [window(duration: nil, elapsed: 500), window(duration: 0, elapsed: 0), window(duration: 1_000, elapsed: -1),
                        window(duration: 1_000, elapsed: 1_000), window(duration: 1_000, elapsed: 500, used: 0), window(duration: 1_000, elapsed: 500, used: nil)] {
        invalid.derive(at: now, groupStale: false)
        #expect(invalid.pacing == nil && invalid.pacingUnavailableReason != nil)
    }
    #expect(GoUsage.retryAfter("3600", at: now) == now.addingTimeInterval(3_600))
    #expect(GoUsage.retryAfter("Wed, 21 Oct 2037 07:28:00 GMT", at: now) != nil)
    #expect(GoUsage.retryAfter("invalid", at: now) == nil)
    #expect(GoUsage.retryAfter("-5", at: now) == nil)
    #expect(GoUsage.retryAfter("inf", at: now) == nil)
}

@Test func activityFailureKeepsItsLastSuccessAndNeverStalesProviderGroups() async throws {
    let scenario = SchedulingScenario()
    let owner = scenario.owner()
    try await owner.refresh(); await owner.waitForCollection()
    let success = await owner.activitySnapshot()
    #expect(success.observedAt == scenario.now() && !success.stale)
    scenario.advance(15)
    scenario.fail("activity", Fault("activity_unavailable", "Synthetic scan failure."))
    try await owner.refresh(); await owner.waitForCollection()
    let failed = await owner.activitySnapshot()
    #expect(failed.stale && failed.observedAt == success.observedAt && failed.lastAttemptAt == scenario.now())
    #expect(await owner.snapshot().accounts.allSatisfy { !$0.groups.quotas.stale })
    let calls = scenario.count("activity")
    scenario.fail("activity", nil)
    #expect(try await owner.refresh(accountIDs: []).activity.state == "started")
    await owner.waitForCollection()
    #expect(scenario.count("activity") == calls + 1)
    scenario.advance(300)
    #expect(await owner.activitySnapshot().stale)
    let unconnected = TallyOwner(clock: { scenario.now() }, inventory: { scenario.inventory() }, collect: { _ in GoObservation(windows: []) })
    try await unconnected.refresh(accountIDs: []); await unconnected.waitForCollection()
    #expect(await unconnected.activitySnapshot().observedAt == nil)
    #expect(await unconnected.activitySnapshot().error?.code == "not_implemented")
}
