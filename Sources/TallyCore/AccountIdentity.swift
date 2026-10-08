import Foundation
import Darwin

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
    var databaseFileIdentity: String? = nil
    var initialized = false
    var observedAt: Date?
    var nextColors: [String: Int] = [:]
    var colorsByCredential: [String: Int]? = nil
    var pinnedOrder: [String]? = nil
    var unpinnedOrder: [String]? = nil
    var records: [IdentityRecord] = []
    var activity: [String: Group<ActivityData>]? = nil
    var warmups: [String: WarmupStatus]? = nil
    var warmupAccountsByCredential: [String: String]? = nil
}

struct AccountIdentityStore {
    struct State: Codable { var namespaces: [String: InventoryNamespace] = [:] }
    var state: State
    let url: URL?
    private let loadError: Fault?
    private var savedData: Data?

    init(url: URL?) {
        self.url = url
        var loaded = State()
        var failure: Fault?
        if let url {
            do {
                let data = try Data(contentsOf: url)
                loaded = try Wire.decoder().decode(State.self, from: data)
                savedData = data
            }
            catch {
                if !Self.missingFile(error) {
                    failure = Fault("settings_storage_unavailable", "Tally could not load Account settings at \(url.path). The original file is retained; restore it and restart Tally before saving preferences.")
                }
            }
        }
        state = loaded
        loadError = failure
        for key in state.namespaces.keys {
            for index in state.namespaces[key]!.records.indices {
                state.namespaces[key]!.records[index].account.groups.restoreStale()
            }
        }
    }

    private static func missingFile(_ error: Error) -> Bool {
        if (error as? CocoaError)?.code == .fileReadNoSuchFile { return true }
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? POSIXError
        return underlying?.code == .ENOTDIR
    }

    mutating func save() throws {
        if let loadError { throw loadError }
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // The collector and a second app/--collect-once must not replace each other's settings snapshots.
            let lockFD = open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lockFD >= 0 else { throw Fault("settings_storage_unavailable", "Tally could not lock Account settings.") }
            defer { close(lockFD) }
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw Fault("settings_storage_unavailable", "Another Tally instance is saving Account settings. Retry the change.") }
            let current: Data?
            do { current = try Data(contentsOf: url) }
            catch {
                guard Self.missingFile(error) else { throw error }
                current = nil
            }
            guard current == savedData else {
                throw Fault("settings_storage_unavailable", "Account settings changed on disk. Quit other Tally instances and restart Tally to load the saved settings; this stale copy will not overwrite them.")
            }
            let data = try Wire.encoder().encode(state)
            try data.write(to: url, options: .atomic)
            savedData = data
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let fault as Fault { throw fault }
        catch { throw Fault("settings_storage_unavailable", "Tally could not save Account preferences and cached readings.") }
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
