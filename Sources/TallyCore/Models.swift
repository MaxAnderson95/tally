import Foundation

// Required nullable wire fields must encode as null, not disappear from successful responses.
@propertyWrapper public struct Null<Value: Codable & Sendable>: Codable, Sendable {
    public var wrappedValue: Value?
    public init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = container.decodeNil() ? nil : try container.decode(Value.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue { try container.encode(wrappedValue) } else { try container.encodeNil() }
    }
}

public struct Fault: Codable, Sendable, Error {
    public var code: String
    public var message: String
    @Null public var retryAt: Date? = nil
    @Null public var blockingOperationId: String? = nil
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

public struct Group<Data: Codable & Sendable>: Codable, Sendable {
    @Null public var data: Data? = nil
    @Null public var observedAt: Date? = nil
    @Null public var lastAttemptAt: Date? = nil
    public var stale = true
    public var refreshing = false
    @Null public var nextAttemptAt: Date? = nil
    @Null public var error: Fault? = nil

    public init() {}
    mutating func succeed(_ data: Data?, at now: Date) {
        self.data = data; observedAt = now
        if lastAttemptAt == nil { lastAttemptAt = now }
        stale = false; refreshing = false; error = nil
    }
    mutating func fail(_ fault: Fault, at now: Date) {
        if lastAttemptAt == nil { lastAttemptAt = now }
        stale = true; refreshing = false; error = fault
    }
    mutating func age(at now: Date) {
        stale = stale || observedAt.map { now.timeIntervalSince($0) >= 300 } ?? true
    }
}

public struct Plan: Codable, Sendable { public var name: String }
public struct Quotas: Codable, Sendable { public var windows: [QuotaWindow] }
public struct Pacing: Codable, Sendable {
    public var projectedUsedPercent: Double
    public var sparePercent: Double
    @Null public var runOutAt: Date? = nil
    @Null public var runOutReason: String? = nil
}
public struct QuotaWindow: Codable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var scope = "account"
    @Null public var scopeNote: String? = nil
    @Null public var modelId: String? = nil
    public var cadence: String
    @Null public var durationSeconds: Double? = nil
    public var durationSource: String
    @Null public var usedPercent: Double? = nil
    @Null public var remainingPercent: Double? = nil
    @Null public var resetAt: Date? = nil
    public var resetState = "unknown"
    public var stale = false
    public var displayInOverview = true
    @Null public var pacing: Pacing? = nil
    @Null public var pacingUnavailableReason: String? = nil

    mutating func derive(at now: Date, groupStale: Bool) {
        remainingPercent = usedPercent.map { min(100, max(0, 100 - $0)) }
        resetState = resetAt.map { $0 <= now ? "passed" : "scheduled" } ?? "unknown"
        stale = groupStale || resetState == "passed"
        pacing = nil
        pacingUnavailableReason = "The reading is stale."
        guard !stale else { return }
        pacingUnavailableReason = "Window duration is unknown or invalid."
        guard let duration = durationSeconds, duration.isFinite, duration > 0 else { return }
        pacingUnavailableReason = "A future reset time is required."
        guard let reset = resetAt, reset > now else { return }
        pacingUnavailableReason = "Positive observed usage is required."
        guard let used = usedPercent, used.isFinite, used > 0 else { return }
        let elapsed = now.timeIntervalSince(reset.addingTimeInterval(-duration))
        pacingUnavailableReason = "The elapsed window must be at least 60 seconds and 1% of its duration, and less than the full duration."
        guard elapsed >= max(60, 0.01 * duration), elapsed < duration else { return }
        let projected = used * duration / elapsed
        let exhaustion = reset.addingTimeInterval(-duration + elapsed * 100 / used)
        pacingUnavailableReason = "The projection is outside the supported numeric range."
        guard projected.isFinite, exhaustion.timeIntervalSince1970.isFinite else { return }
        pacing = Pacing(projectedUsedPercent: projected, sparePercent: 100 - projected,
                        runOutAt: exhaustion < reset ? exhaustion : nil,
                        runOutReason: exhaustion < reset ? nil : "Allowance is projected to last through reset.")
        pacingUnavailableReason = nil
    }
}

// Go has no observations for these groups. Other provider slices add their concrete data types.
public struct AbsentData: Codable, Sendable {}
public struct AccountGroups: Codable, Sendable {
    public var plan = Group<Plan>()
    public var quotas = Group<Quotas>()
    public var extraUsage = Group<AbsentData>()
    public var balances = Group<AbsentData>()
    public var resetSummary = Group<AbsentData>()
    public var resetDetails = Group<AbsentData>()
}
public struct PinLine: Codable, Sendable {
    public var windowId: String
    public var label: String
    @Null public var remainingPercent: Double? = nil
    public var stale: Bool
}
public struct Pin: Codable, Sendable { public var lines: [PinLine] = []; public var warning = false }
public struct CommandSummary: Codable, Sendable {
    @Null public var blockingOperationId: String? = nil
    @Null public var state: String? = nil
    public var acknowledgementRequired = false
}
public struct Account: Codable, Sendable, Identifiable {
    public var id: String
    public var provider = "opencode-go"
    public var service = "opencode-go"
    public var name: String
    public var pinned = true
    @Null public var pinOrder: Int? = nil
    public var identityColorIndex = 0
    public var pin = Pin()
    public var groups = AccountGroups()
    public var command = CommandSummary()
}
public struct Inventory: Codable, Sendable { public var count: Int; public var namespaceId: String }
public struct RecoveryStorage: Codable, Sendable {
    public var available = false
    @Null public var error: Fault? = Fault("not_implemented", "Command recovery storage is not available in this slice.")
}
public struct Status: Codable, Sendable {
    public var apiMajor = 1
    public var appBuild: String
    public var serverTime: Date
    public var timezone: String
    public var owner: String
    public var inventory: Group<Inventory>
    public var recoveryStorage = RecoveryStorage()
}
public struct AccountsResponse: Codable, Sendable { public var status: Status; public var accounts: [Account] }
public struct AccountResponse: Codable, Sendable { public var status: Status; public var account: Account }
public struct Schedule: Codable, Sendable {
    public var state: String
    @Null public var nextAttemptAt: Date? = nil
    @Null public var reason: Fault? = nil
}
public struct AccountSchedule: Codable, Sendable { public var accountId: String; public var schedule: Schedule }
public struct RefreshResponse: Codable, Sendable { public var accounts: [AccountSchedule]; public var activity: Schedule }

public enum Wire {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try value.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]; return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            let text = try value.decode(String.self)
            if let date = try? Date(text, strategy: .iso8601) { return date }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "Expected an RFC 3339 instant.")
            }
            return date
        }
        return decoder
    }
}
