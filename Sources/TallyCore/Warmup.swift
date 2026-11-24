import Foundation

public struct WarmupModel: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
}

public struct WarmupReading: Codable, Sendable {
    public var enabled: Bool
    public var model: String
    @Null public var startTime: String? = nil
    @Null public var nextAt: Date?
    @Null public var lastAttemptAt: Date?
    public var message: String
    public var needsAttention: Bool
    @Null public var unavailableReason: String?
}

public enum WarmupAvailability: Sendable {
    case available, unknown, unnecessary

    public var reason: String? {
        switch self {
        case .available: nil
        case .unknown: "Waiting for quota information"
        case .unnecessary: "No applicable five-hour window"
        }
    }
}

public struct WarmupStatus: Codable, Sendable, Equatable {
    public var enabled = false
    public var model = ""
    public var startTime: String? = nil
    public var nextAt: Date?
    public var lastAttemptAt: Date?
    public var message = "Off"
    var resetAt: Date?
    var scheduleTimeZone: String? = nil
    var suspended = false
    var promptIndex: Int?
    var revision = UUID().uuidString

    public init() {}

    public var needsAttention: Bool { enabled && suspended }

    /// Minimum headroom before a daily cutoff so a 120-second quota poll can confirm the post-schedule reading in time.
    static let pollHeadroom: TimeInterval = 180

    public static func parseStartTime(_ value: String?) -> (hour: Int, minute: Int)? {
        guard let value else { return nil }
        let bytes = Array(value.utf8)
        guard bytes.count == 5, bytes[2] == UInt8(ascii: ":") else { return nil }
        func digit(_ byte: UInt8) -> Int? {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            return Int(byte - UInt8(ascii: "0"))
        }
        guard let h1 = digit(bytes[0]), let h2 = digit(bytes[1]),
              let m1 = digit(bytes[3]), let m2 = digit(bytes[4]) else { return nil }
        let hour = h1 * 10 + h2
        let minute = m1 * 10 + m2
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return (hour, minute)
    }

    public static func formatStartTime(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    private static func dailyStart(on dayStart: Date, hour: Int, minute: Int, calendar: Calendar) -> Date {
        let target = DateComponents(hour: hour, minute: minute, second: 0)
        return calendar.nextDate(after: dayStart.addingTimeInterval(-1), matching: target, matchingPolicy: .nextTime, repeatedTimePolicy: .first) ?? dayStart
    }

    private static func activeWindow(for date: Date, hour: Int, minute: Int, calendar: Calendar) -> (start: Date, cutoff: Date, nextStart: Date) {
        let day = calendar.dateInterval(of: .day, for: date)
        let dayStart = day?.start ?? calendar.startOfDay(for: date)
        let nextDayStart = day?.end ?? calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let start = dailyStart(on: dayStart, hour: hour, minute: minute, calendar: calendar)
        let nextStart = dailyStart(on: nextDayStart, hour: hour, minute: minute, calendar: calendar)
        // Auto warm-ups stop at midnight and also avoid starting a five-hour window that would overlap tomorrow's start time.
        let cutoff = min(nextDayStart, nextStart.addingTimeInterval(-18_000))
        return (start, cutoff, nextStart)
    }

    static func earliestAllowedStart(at date: Date, startTime: String?, timezone: TimeZone) -> Date {
        guard let (hour, minute) = parseStartTime(startTime) else { return date }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let window = activeWindow(for: date, hour: hour, minute: minute, calendar: calendar)
        if date < window.start { return window.start }
        if date < window.cutoff { return date }
        return window.nextStart
    }

    static func isAllowedStart(_ date: Date, startTime: String?, timezone: TimeZone) -> Bool {
        earliestAllowedStart(at: date, startTime: startTime, timezone: timezone) == date
    }

    private static func fitIntoWindow(_ window: (start: Date, cutoff: Date, nextStart: Date), delay: TimeInterval) -> Date {
        let maxOffset = max(0, window.cutoff.timeIntervalSince(window.start) - pollHeadroom)
        return window.start.addingTimeInterval(min(delay, maxOffset))
    }

    private func hasValidSchedule(timezone: TimeZone) -> Bool {
        guard let nextAt else { return false }
        guard Self.isAllowedStart(nextAt, startTime: startTime, timezone: timezone) else { return false }
        return startTime == nil || scheduleTimeZone == timezone.identifier
    }

    private mutating func setScheduledTime(from base: Date, timezone: TimeZone, jitter: () -> TimeInterval) {
        guard let (hour, minute) = Self.parseStartTime(startTime) else {
            nextAt = base.addingTimeInterval(jitter())
            scheduleTimeZone = nil
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let allowed = Self.earliestAllowedStart(at: base, startTime: startTime, timezone: timezone)
        let window = Self.activeWindow(for: allowed, hour: hour, minute: minute, calendar: calendar)
        let delay = max(0, jitter())
        let latestSafe = max(window.start, window.cutoff.addingTimeInterval(-Self.pollHeadroom))
        if allowed == window.start {
            nextAt = Self.fitIntoWindow(window, delay: delay)
        } else {
            let candidate = allowed.addingTimeInterval(delay)
            if candidate <= latestSafe {
                nextAt = candidate
            } else if allowed <= latestSafe && window.cutoff.timeIntervalSince(window.start) < 1200 + Self.pollHeadroom {
                nextAt = latestSafe
            } else {
                let nextWindow = Self.activeWindow(for: window.nextStart, hour: hour, minute: minute, calendar: calendar)
                nextAt = Self.fitIntoWindow(nextWindow, delay: delay)
            }
        }
        scheduleTimeZone = timezone.identifier
    }

    public static func availability(quotas: Group<Quotas>, model: String, now: Date = Date()) -> WarmupAvailability {
        guard !quotas.stale, quotas.error == nil, let observed = quotas.observedAt,
              now.timeIntervalSince(observed) < 300, let windows = quotas.data?.windows else { return .unknown }
        let modelID = model.split(separator: "/", maxSplits: 1).last.map(String.init) ?? ""
        if windows.contains(where: { $0.durationSeconds == 18_000 && $0.cadence == "rolling" && ($0.scope == "account" || $0.scope == "model" && (model.isEmpty || $0.modelId == modelID)) }) {
            return .available
        }
        let unknown = windows.contains { $0.durationSeconds == nil && $0.cadence != "monthly" || $0.scope == "other" && $0.durationSeconds == 18_000 }
        return unknown ? .unknown : .unnecessary
    }

    mutating func prepare(quotas: Group<Quotas>, now: Date, timezone: TimeZone = .current, jitter: () -> TimeInterval) -> Bool {
        guard enabled, !suspended else { return false }
        let availability = Self.availability(quotas: quotas, model: model, now: now)
        guard case .available = availability else {
            if availability == .unnecessary { nextAt = nil; resetAt = nil; scheduleTimeZone = nil }
            message = availability == .unnecessary ? "Not needed: no applicable five-hour window" : "Waiting for quota information"
            return false
        }
        guard let observed = quotas.observedAt, let windows = quotas.data?.windows else { return false }
        let modelID = model.split(separator: "/", maxSplits: 1).last.map(String.init) ?? ""
        let applicable = windows.filter { $0.scope == "account" || ($0.scope == "model" && $0.modelId == modelID) }
        let candidates = applicable.filter { $0.durationSeconds == 18_000 && $0.cadence == "rolling" }
        guard !candidates.isEmpty else {
            nextAt = nil; resetAt = nil; scheduleTimeZone = nil
            message = "Choose a model with an applicable five-hour window"
            return false
        }
        // Every applicable short window must be idle before a message can start a new one.
        guard candidates.allSatisfy({ $0.usedPercent != nil }) else {
            message = "Waiting for known usage"
            return false
        }
        let blocked = applicable.filter { ($0.usedPercent ?? 100) >= 100 && ($0.resetAt == nil || $0.resetAt! > now) }
        if !blocked.isEmpty {
            if blocked.allSatisfy({ $0.resetAt != nil }),
               let reset = (blocked + candidates.filter { ($0.usedPercent ?? 0) > 0 }).compactMap(\.resetAt).max() {
                if resetAt != reset || !hasValidSchedule(timezone: timezone) {
                    resetAt = reset
                    setScheduledTime(from: reset, timezone: timezone, jitter: jitter)
                }
            } else { nextAt = nil; scheduleTimeZone = nil }
            message = "Waiting for available allowance"
            return false
        }
        if let reset = candidates.filter({ ($0.usedPercent ?? 0) > 0 }).compactMap(\.resetAt).filter({ $0 > now }).max() {
            if resetAt != reset || !hasValidSchedule(timezone: timezone) {
                resetAt = reset
                setScheduledTime(from: reset, timezone: timezone, jitter: jitter)
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
            let earliest = lastAttemptAt.addingTimeInterval(18_000)
            let allowed = Self.earliestAllowedStart(at: earliest, startTime: startTime, timezone: timezone)
            if !hasValidSchedule(timezone: timezone) || nextAt! < allowed {
                setScheduledTime(from: earliest, timezone: timezone, jitter: jitter)
            }
            message = "Waiting for the next five-hour window"
            return false
        }
        let earliest = Self.earliestAllowedStart(at: now, startTime: startTime, timezone: timezone)
        if earliest > now {
            if !hasValidSchedule(timezone: timezone) || nextAt! < earliest {
                setScheduledTime(from: earliest, timezone: timezone, jitter: jitter)
            }
            message = "Waiting for daily start time"
            return false
        }
        // Restart and wake never replay a backlog of missed windows.
        if !hasValidSchedule(timezone: timezone) || now.timeIntervalSince(nextAt!) > 1200 {
            setScheduledTime(from: now, timezone: timezone, jitter: jitter)
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
        scheduleTimeZone = nil
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
