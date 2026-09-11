import Foundation
import CSQLite

/// Runs a single turn without sharing OpenCode's active Account, configuration, or sessions.
struct OpenCodeWarmup: Sendable {
    var executable: URL
    var anthropicPluginPath = ""

    static func defaultExecutable() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.local/bin/opencode2", home + "/.opencode/bin/opencode2", "/opt/homebrew/bin/opencode2"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? home + "/.local/bin/opencode2"
    }

    func send(_ request: WarmupRequest) async throws {
        try await withWorkspace(request) { root, environment in
            let choices = try await availableModels(provider: request.credential.provider, root: root, environment: environment)
            guard choices.contains(where: { $0.id == request.model }) else {
                throw Fault("warmup_model_unavailable", "Selected model is no longer available. Choose another warm-up model.")
            }
            try Task.checkCancellation()
            let output = try await run(["run", "--server", environment["TALLY_PRIVATE_SERVER"]!, "--model", request.model, "--agent", "tally-warmup", "--title", "Tally window warm-up", "--format", "json", request.prompt], root: root, environment: environment)
            struct Event: Decodable { var type: String }
            let events = output.split(separator: 10).compactMap { try? JSONDecoder().decode(Event.self, from: Data($0)) }
            guard events.contains(where: { $0.type == "step_finish" }), !events.contains(where: { $0.type == "error" }) else {
                throw Fault("warmup_unconfirmed", "OpenCode did not confirm a completed turn. Warm-up is paused; no automatic retry.")
            }
        }
    }

    func models(_ request: WarmupRequest) async throws -> [WarmupModel] {
        try await withWorkspace(request) { root, environment in
            try await availableModels(provider: request.credential.provider, root: root, environment: environment)
        }
    }

    private func availableModels(provider: String, root: URL, environment: [String: String]) async throws -> [WarmupModel] {
        let server = environment["TALLY_PRIVATE_SERVER"]!
        _ = try await run(["api", "--server", server, "post", "/api/plugin/await-activation"], root: root, environment: environment)
        let data = try await run(["api", "--server", server, "get", "/api/model"], root: root, environment: environment)
        return try Self.decodeModels(data, provider: provider)
    }

    static func decodeModels(_ data: Data, provider: String) throws -> [WarmupModel] {
        struct Model: Decodable { var id: String; var providerID: String; var name: String; var enabled: Bool; var status: String }
        struct Response: Decodable { var data: [Model] }
        return try JSONDecoder().decode(Response.self, from: data).data
            .filter { $0.providerID == provider && $0.enabled && $0.status != "deprecated" }
            .map { WarmupModel(id: $0.providerID + "/" + $0.id, name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func withWorkspace<T: Sendable>(_ request: WarmupRequest, action: (URL, [String: String]) async throws -> T) async throws -> T {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw Fault("warmup_executable", "Choose an installed OpenCode V2 executable in Settings.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tally-warmup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("opencode.db")
        var environment = try Self.environment(root: root)
        if request.credential.provider == "anthropic" {
            guard anthropicPluginPath.hasPrefix("/"), FileManager.default.fileExists(atPath: anthropicPluginPath) else {
                throw Fault("warmup_auth_plugin", "Select your installed Claude subscription auth plugin directory in Settings.")
            }
            var config = try JSONSerialization.jsonObject(with: Data(environment["OPENCODE_CONFIG_CONTENT"]!.utf8)) as! [String: Any]
            config["plugins"] = [anthropicPluginPath]
            environment["OPENCODE_CONFIG_CONTENT"] = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        }
        environment["OPENCODE_PASSWORD"] = UUID().uuidString + UUID().uuidString
        let process = Process()
        let lease = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["serve", "--stdio", "--hostname", "127.0.0.1", "--port", "0"]
        process.currentDirectoryURL = root; process.environment = environment
        process.standardInput = lease; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        try process.run()
        defer {
            try? lease.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            output.fileHandleForReading.readabilityHandler = nil
            // No tool processes are permitted; closing the lease stops the private server.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        let server = try await Self.readServerURL(output.fileHandleForReading, process: process)
        output.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        environment["TALLY_PRIVATE_SERVER"] = server
        try Self.copyCredential(request, to: database)
        return try await action(root, environment)
    }

    private static func readServerURL(_ handle: FileHandle, process: Process) async throws -> String {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(descriptor, F_SETFL, flags) }
        var data = Data()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while process.isRunning && ContinuousClock.now < deadline && data.count < 16_384 {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
            if let end = data.firstIndex(of: 10) {
                struct Ready: Decodable { var url: String }
                let ready = try JSONDecoder().decode(Ready.self, from: data.prefix(upTo: end))
                guard let url = URL(string: ready.url), url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
                    throw Fault("warmup_server", "OpenCode did not start on a private loopback port.")
                }
                return ready.url
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Fault("warmup_server", "OpenCode V2 did not start its private server.")
    }

    static func environment(root: URL) throws -> [String: String] {
        let config: [String: Any] = [
            "update": "disable", "share": "disabled", "snapshots": false, "warming": false,
            "permissions": [["action": "*", "resource": "*", "effect": "deny"]],
            "agents": [
                "tally-warmup": ["mode": "primary", "steps": 1, "system": "Answer the question in one short sentence. Do not use tools."],
                "title": ["disabled": true], "summary": ["disabled": true]
            ]
        ]
        let content = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        return [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "HOME": root.path,
            "PWD": root.path, "TMPDIR": root.path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_DATA_HOME": root.appendingPathComponent("data").path,
            "XDG_CACHE_HOME": root.appendingPathComponent("cache").path,
            "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "OPENCODE_DB": root.appendingPathComponent("opencode.db").path,
            "OPENCODE_CONFIG_PROJECT_DISABLE": "1", "OPENCODE_FILEWATCHER_DISABLE": "1",
            "OPENCODE_CONFIG_CONTENT": content
        ]
    }

    private func run(_ arguments: [String], root: URL, environment: [String: String]) async throws -> Data {
        let output = root.appendingPathComponent("output-" + UUID().uuidString)
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.currentDirectoryURL = root; process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        do {
            while process.isRunning {
                guard ContinuousClock.now < deadline else { throw Fault("warmup_timeout", "OpenCode timed out. Warm-up is paused; no automatic retry.") }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            process.terminate()
            // Standalone's server lease ends when the CLI exits, including after SIGKILL.
            for _ in 0..<30 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw error
        }
        guard process.terminationStatus == 0 else {
            throw Fault("warmup_failed", "OpenCode failed. Check the model and credentials, then toggle warm-up off and on. No automatic retry.")
        }
        guard (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0 <= 8_000_000 else {
            throw Fault("warmup_output", "OpenCode returned too much output. Warm-up is paused.")
        }
        return try Data(contentsOf: output)
    }

    static func copyCredential(_ request: WarmupRequest, to destination: URL, now: Date = Date()) throws {
        let source = OpenCodeInventory(path: request.databasePath)
        let current = try source.read().credentials.first { $0.storedID == request.credential.storedID && $0.provider == request.credential.provider }
        guard let current, current.evidence.relation(to: request.credential.evidence) == .same,
              current.expiresAt.map({ $0.timeIntervalSince(now) > 600 }) ?? true else {
            throw Fault("warmup_credentials", "Account changed or its token expires soon. Refresh it in OpenCode before resuming warm-up.")
        }
        var input: OpaquePointer?
        var output: OpaquePointer?
        guard sqlite3_open_v2(request.databasePath, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let input { sqlite3_close(input) }
            throw Fault("warmup_database", "Cannot read the selected OpenCode database.")
        }
        defer { sqlite3_close(input) }
        guard sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let output { sqlite3_close(output) }
            throw Fault("warmup_database", "OpenCode did not initialize its private database.")
        }
        defer { sqlite3_close(output) }
        sqlite3_busy_timeout(input, 1000); sqlite3_busy_timeout(output, 1000)
        var read: OpaquePointer?
        var write: OpaquePointer?
        defer { sqlite3_finalize(read); sqlite3_finalize(write) }
        let sql = "SELECT value FROM credential WHERE id = ? AND integration_id = ?"
        guard sqlite3_prepare_v2(input, sql, -1, &read, nil) == SQLITE_OK else { throw Fault("warmup_schema", "OpenCode credential schema changed.") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(read, 1, current.storedID, -1, transient)
        sqlite3_bind_text(read, 2, current.provider, -1, transient)
        guard sqlite3_step(read) == SQLITE_ROW, let bytes = sqlite3_column_text(read, 0) else { throw Fault("warmup_credentials", "Account disappeared before warm-up.") }
        var value = String(cString: bytes)
        // Recheck the exact copied value, not just the earlier inventory read, before writing.
        struct Value: Decodable { var key: String?; var access: String?; var expires: Double? }
        let decoded = try JSONDecoder().decode(Value.self, from: Data(value.utf8))
        guard (decoded.key ?? decoded.access) == current.key,
              decoded.expires.map({ $0 / 1000 > now.timeIntervalSince1970 + 600 }) ?? (current.expiresAt == nil) else {
            throw Fault("warmup_credentials", "Credentials changed during warm-up preparation.")
        }
        if current.expiresAt != nil {
            var object = try JSONSerialization.jsonObject(with: Data(value.utf8)) as! [String: Any]
            // A Mac can sleep mid-turn. Even then this disposable database must not rotate
            // a refresh token whose replacement the real OpenCode database would never receive.
            object["refresh"] = ""
            value = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let insert = "INSERT INTO credential (id, integration_id, label, value, active, time_created, time_updated) VALUES (?, ?, 'Tally warm-up', ?, 1, ?, ?)"
        guard sqlite3_prepare_v2(output, insert, -1, &write, nil) == SQLITE_OK else { throw Fault("warmup_schema", "Installed OpenCode V2 has an incompatible credential schema.") }
        sqlite3_bind_text(write, 1, current.storedID, -1, transient)
        sqlite3_bind_text(write, 2, current.provider, -1, transient)
        sqlite3_bind_text(write, 3, value, -1, transient)
        sqlite3_bind_int64(write, 4, Int64(now.timeIntervalSince1970 * 1000))
        sqlite3_bind_int64(write, 5, Int64(now.timeIntervalSince1970 * 1000))
        guard sqlite3_step(write) == SQLITE_DONE else { throw Fault("warmup_database", "Cannot prepare the private Account database.") }
    }
}
