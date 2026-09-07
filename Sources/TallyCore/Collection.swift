import Foundation

// One job is one independently collected endpoint. Its groups share an attempt, not other jobs' failures.
struct CollectionJob: Sendable {
    var id: String
    var groups: [ReadingGroup]
    var run: @Sendable () async throws -> [GroupObservation]

    static func go(_ collect: @escaping @Sendable () async throws -> GoObservation) -> CollectionJob {
        CollectionJob(id: "usage", groups: ReadingGroup.allCases) {
            let observation = try await collect()
            return [.plan(Plan(name: "Go")), .quotas(Quotas(windows: observation.windows)),
                    .extraUsage(nil), .balances(nil), .resetSummary(nil), .resetDetails(nil)]
        }
    }
}

enum ReadingGroup: String, CaseIterable, Sendable {
    case plan, quotas, extraUsage, balances, resetSummary, resetDetails

    func update(_ groups: inout AccountGroups, attempt: Date? = nil, next: Date?, fault: Fault? = nil, refreshing: Bool = false) {
        func apply<T>(_ group: inout Group<T>) {
            if let attempt { group.lastAttemptAt = attempt }
            group.nextAttemptAt = next; group.refreshing = refreshing
            if let fault { group.stale = true; group.error = fault }
        }
        switch self {
        case .plan: apply(&groups.plan)
        case .quotas: apply(&groups.quotas)
        case .extraUsage: apply(&groups.extraUsage)
        case .balances: apply(&groups.balances)
        case .resetSummary: apply(&groups.resetSummary)
        case .resetDetails: apply(&groups.resetDetails)
        }
    }
}

enum GroupObservation: Sendable {
    case plan(Plan?), quotas(Quotas?), extraUsage(AbsentData?), balances(AbsentData?), resetSummary(AbsentData?), resetDetails(AbsentData?)

    var group: ReadingGroup {
        switch self {
        case .plan: .plan
        case .quotas: .quotas
        case .extraUsage: .extraUsage
        case .balances: .balances
        case .resetSummary: .resetSummary
        case .resetDetails: .resetDetails
        }
    }

    func apply(to groups: inout AccountGroups, at now: Date) {
        switch self {
        case .plan(let data): groups.plan.succeed(data, at: now)
        case .quotas(let data): groups.quotas.succeed(data, at: now)
        case .extraUsage(let data): groups.extraUsage.succeed(data, at: now)
        case .balances(let data): groups.balances.succeed(data, at: now)
        case .resetSummary(let data): groups.resetSummary.succeed(data, at: now)
        case .resetDetails(let data): groups.resetDetails.succeed(data, at: now)
        }
    }
}

struct AttemptPolicy: Codable, Sendable {
    var lastAttemptAt: Date?
    var nextAttemptAt: Date?
    var cooldownUntil: Date?
    var failures = 0
    var blockedCredential: String?

    func decision(at now: Date, automatic: Bool) -> Schedule? {
        let deadlines = [cooldownUntil, lastAttemptAt?.addingTimeInterval(15), automatic ? nextAttemptAt : nil].compactMap { $0 }
        if let deadline = deadlines.max(), deadline > now {
            var fault = Fault(cooldownUntil.map { $0 > now } == true ? "provider_cooldown" : "refresh_deferred", "The next collection attempt is scheduled.")
            fault.retryAt = deadline
            return Schedule(state: "deferred", nextAttemptAt: deadline, reason: fault)
        }
        return nil
    }

    mutating func start(at now: Date) {
        lastAttemptAt = now; nextAttemptAt = nil
    }

    mutating func finish(at now: Date, fault: Fault?, credential: String? = nil) -> Fault? {
        guard var fault else {
            failures = 0; cooldownUntil = nil; blockedCredential = nil
            nextAttemptAt = now.addingTimeInterval(120)
            return nil
        }
        failures = min(max(failures, 0), 3) + 1
        if fault.code == "credentials_rejected" || fault.code == "credentials_expired" {
            blockedCredential = credential; nextAttemptAt = nil; cooldownUntil = nil
        } else {
            let delay: TimeInterval = [120, 240, 480, 900][failures - 1]
            let deadline = max(now.addingTimeInterval(delay), fault.retryAt ?? now)
            cooldownUntil = deadline; nextAttemptAt = deadline; fault.retryAt = deadline
        }
        return fault
    }
}
