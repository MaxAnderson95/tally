import Foundation

/// Private-to-the-Mac evidence for command recovery. Never encode this in REST responses.
public struct IdentityEvidence: Codable, Sendable {
    public enum Relation: Sendable { case same, different, uncertain }
    public var provider: String
    var workspace: String?
    var tokens: Set<String>

    public func relation(to other: IdentityEvidence) -> Relation {
        guard provider == other.provider else { return .different }
        if provider == "openai" {
            if let workspace, let otherWorkspace = other.workspace {
                return workspace == otherWorkspace ? .same : .different
            }
            // A missing selector must not collapse into a known workspace, even with shared tokens.
            guard workspace == other.workspace else { return .uncertain }
        }
        return tokens.isDisjoint(with: other.tokens) ? .uncertain : .same
    }
}

struct IdentityRecord: Codable {
    var evidence: IdentityEvidence
    var account: Account
    var present: Bool
    var attempts: [String: AttemptPolicy]? = nil
}

struct InventoryNamespace: Codable {
    var id = UUID().uuidString
    var initialized = false
    var observedAt: Date?
    var nextColors: [String: Int] = [:]
    var colorsByCredential: [String: Int]? = nil
    var pinnedOrder: [String]? = nil
    var unpinnedOrder: [String]? = nil
    var records: [IdentityRecord] = []
    var activity: [String: Group<ActivityData>]? = nil
}

struct AccountIdentityStore {
    struct State: Codable { var namespaces: [String: InventoryNamespace] = [:] }
    var state: State
    let url: URL?

    init(url: URL?) {
        self.url = url
        state = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? Wire.decoder().decode(State.self, from: $0) } ?? State()
        for key in state.namespaces.keys {
            for index in state.namespaces[key]!.records.indices {
                state.namespaces[key]!.records[index].account.groups.restoreStale()
            }
        }
    }

    func save() throws {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Wire.encoder().encode(state).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw Fault("settings_storage_unavailable", "Tally could not save Account preferences and cached readings.") }
    }
}

extension AccountGroups {
    mutating func restoreStale() {
        plan.stale = true; plan.refreshing = false
        quotas.stale = true; quotas.refreshing = false
        extraUsage.stale = true; extraUsage.refreshing = false
        balances.stale = true; balances.refreshing = false
        resetSummary.stale = true; resetSummary.refreshing = false
        resetDetails.stale = true; resetDetails.refreshing = false
    }
}

let providerOrder = ["anthropic", "openai", "opencode-go", "xai"]
let providerServices = ["anthropic": "claude-subscription", "openai": "chatgpt-subscription", "opencode-go": "opencode-go", "xai": "grok-subscription"]

func accountOrder(_ lhs: Account, _ rhs: Account) -> Bool {
    if lhs.pinned != rhs.pinned { return lhs.pinned }
    if lhs.pinned, lhs.pinOrder != rhs.pinOrder { return (lhs.pinOrder ?? 0) < (rhs.pinOrder ?? 0) }
    if lhs.provider != rhs.provider { return providerOrder.firstIndex(of: lhs.provider)! < providerOrder.firstIndex(of: rhs.provider)! }
    if lhs.name.lowercased() != rhs.name.lowercased() { return lhs.name.lowercased() < rhs.name.lowercased() }
    if lhs.name != rhs.name { return lhs.name < rhs.name }
    return lhs.id < rhs.id
}
