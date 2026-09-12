import Foundation

public struct WarmupModel: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
}

public struct WarmupStatus: Codable, Sendable, Equatable {
    public var enabled = false
    public var model = ""
    public var nextAt: Date?
    public var lastAttemptAt: Date?
    public var message = "Off"
    var resetAt: Date?
    var suspended = false
    var promptIndex: Int?
    var revision = UUID().uuidString

    public init() {}

    public var needsAttention: Bool { enabled && suspended }

    mutating func prepare(quotas: Group<Quotas>, now: Date, jitter: () -> TimeInterval) -> Bool {
        guard enabled, !suspended else { return false }
        guard !quotas.stale, quotas.error == nil, let observed = quotas.observedAt,
              now.timeIntervalSince(observed) < 300, let windows = quotas.data?.windows else {
            nextAt = nil; resetAt = nil
            message = "Waiting for quota information"
            return false
        }
        let modelID = model.split(separator: "/", maxSplits: 1).last.map(String.init) ?? ""
        let applicable = windows.filter { $0.scope == "account" || ($0.scope == "model" && $0.modelId == modelID) }
        let candidates = applicable.filter { $0.durationSeconds == 18_000 && $0.cadence == "rolling" }
        guard !candidates.isEmpty else {
            nextAt = nil; resetAt = nil
            let unknown = windows.contains { $0.durationSeconds == nil && $0.cadence != "monthly" || $0.scope == "other" && $0.durationSeconds == 18_000 }
            message = unknown ? "Waiting for quota information" : "Not needed: no applicable five-hour window"
            return false
        }
        // Every applicable short window must be idle before a message can start a new one.
        guard candidates.allSatisfy({ $0.usedPercent != nil }) else {
            message = "Waiting for known usage"
            return false
        }
        if applicable.contains(where: { ($0.usedPercent ?? 100) >= 100 && ($0.resetAt == nil || $0.resetAt! > now) }) {
            message = "Waiting for available allowance"
            return false
        }
        if let reset = candidates.filter({ ($0.usedPercent ?? 0) > 0 }).compactMap(\.resetAt).filter({ $0 > now }).max() {
            if resetAt != reset {
                resetAt = reset
                nextAt = reset.addingTimeInterval(jitter())
            }
            message = "Scheduled after the current window"
            return false
        }
        // A passed timestamp alone does not prove the provider has restored allowance.
        if candidates.contains(where: { ($0.usedPercent ?? 0) >= 100 || ($0.resetAt.map { $0 <= now && observed < $0 } ?? false) }) {
            message = "Waiting for the provider to confirm reset"
            return false
        }
        if candidates.contains(where: { ($0.usedPercent ?? 0) > 0 && $0.resetAt == nil }) {
            message = "Waiting for a reset time"
            return false
        }
        if let lastAttemptAt, now < lastAttemptAt.addingTimeInterval(18_000) {
            message = "Waiting for the next five-hour window"
            return false
        }
        // Restart and wake never replay a backlog of missed windows.
        if nextAt == nil || now.timeIntervalSince(nextAt!) > 1200 {
            nextAt = now.addingTimeInterval(jitter())
        }
        message = "Scheduled"
        if nextAt! <= now && observed < nextAt! {
            message = "Waiting for a post-schedule quota reading"
            return false
        }
        return nextAt! <= now
    }

    mutating func claim(at now: Date) -> String {
        let choices = Self.prompts.indices.filter { $0 != promptIndex }
        promptIndex = choices.randomElement()!
        lastAttemptAt = now
        nextAt = nil
        // Persist before sending. A crash or ambiguous result must never resend.
        suspended = true
        message = "Sending; if interrupted, toggle off and on to resume"
        return Self.prompts[promptIndex!]
    }

    static let prompts = [
        "What is the capital of France?", "How many letters are in Mississippi?",
        "How many r's are in strawberry?", "What is 17 plus 26?",
        "What is the chemical symbol for gold?", "How many sides does a hexagon have?",
        "Which planet is closest to the Sun?", "What is the square root of 144?",
        "What is the capital of Japan?", "How many minutes are in two hours?",
        "What is the opposite of clockwise?", "What is 9 times 7?",
        "How many vowels are in banana?", "What is the largest ocean?",
        "What is the capital of Canada?", "What is the freezing point of water in Celsius?",
        "How many centimeters are in a meter?", "Which month follows September?",
        "What is the Roman numeral for ten?", "What is the plural of mouse?"
    ]
}

struct WarmupRequest: Sendable {
    var credential: StoredCredential
    var model: String
    var prompt: String
}
