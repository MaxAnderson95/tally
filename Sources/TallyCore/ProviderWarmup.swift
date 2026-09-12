import Foundation

struct ProviderWarmup: Sendable {
    var transport: @Sendable (URLRequest) async throws -> ResetHTTPResponse = { try await SingleSendHTTP.send($0) }

    func models(_ credential: StoredCredential) async throws -> [WarmupModel] {
        let path: String
        switch credential.provider {
        case "openai": path = "models?client_version=0.0.0"
        case "xai": path = "language-models"
        default: path = "models"
        }
        var request = try request(credential, path: path)
        var result: [WarmupModel] = []
        while true {
            let response = try await transport(request)
            try check(response)
            result += try Self.decodeModels(response.body, provider: credential.provider)
            struct Page: Decodable { var has_more: Bool?; var last_id: String? }
            let page = try JSONDecoder().decode(Page.self, from: response.body)
            guard credential.provider == "anthropic", page.has_more == true else { break }
            guard let last = page.last_id, !last.isEmpty, result.count < 2000 else {
                throw Fault("warmup_models", "Provider model pagination could not be completed.")
            }
            var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "after_id", value: last)]
            guard url.url != request.url else { throw Fault("warmup_models", "Provider repeated a model page.") }
            request.url = url.url
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func decodeModels(_ data: Data, provider: String) throws -> [WarmupModel] {
        struct Model: Decodable {
            var id: String?; var slug: String?; var display_name: String?; var name: String?; var visibility: String?
        }
        struct Payload: Decodable { var data: [Model]?; var models: [Model]? }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let models = payload.data ?? payload.models else { throw Fault("warmup_models", "Provider returned no model list.") }
        return try models.filter { $0.visibility == nil || $0.visibility == "list" }.map { model in
            guard let id = model.id ?? model.slug, !id.isEmpty else { throw Fault("warmup_models", "Provider returned an invalid model.") }
            return WarmupModel(id: provider + "/" + id, name: model.display_name ?? model.name ?? id)
        }
    }

    func send(_ input: WarmupRequest) async throws {
        guard try await models(input.credential).contains(where: { $0.id == input.model }) else {
            throw Fault("warmup_model_unavailable", "Selected model is no longer available. Choose another warm-up model.")
        }
        let model = String(input.model.dropFirst(input.credential.provider.count + 1))
        let sessionID = UUID().uuidString
        var body: [String: Any]
        let path: String
        switch input.credential.provider {
        case "anthropic":
            path = "messages?beta=true"
            body = ["model": model, "max_tokens": 64, "stream": true, "messages": [["role": "user", "content": [["type": "text", "text": input.prompt]]]],
                    "system": [
                        ["type": "text", "text": "x-anthropic-billing-header: cc_version=2.1.257.1a0; cc_entrypoint=sdk-cli;"],
                        ["type": "text", "text": "You are a Claude agent, built on Anthropic's Claude Agent SDK."]
                    ]]
        case "openai", "opencode-go":
            path = "responses"
            body = ["model": model, "store": false, "stream": true, "instructions": "Answer in one short sentence. Do not use tools.",
                    "tool_choice": "auto", "parallel_tool_calls": false, "include": ["reasoning.encrypted_content"], "prompt_cache_key": sessionID,
                    "input": [["role": "user", "content": [["type": "input_text", "text": input.prompt]]]]]
        default:
            path = "chat/completions"
            body = ["model": model, "max_tokens": 64, "stream": false,
                    "messages": [["role": "user", "content": input.prompt]]]
        }
        var request = try request(input.credential, path: path)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if ["openai", "opencode-go"].contains(input.credential.provider) { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        if input.credential.provider == "openai" {
            request.setValue(sessionID, forHTTPHeaderField: "session-id")
            request.setValue("remote_compaction_v2", forHTTPHeaderField: "x-codex-beta-features")
        }
        if input.credential.provider == "opencode-go" {
            request.setValue(sessionID, forHTTPHeaderField: "x-opencode-session")
            request.setValue("tally", forHTTPHeaderField: "x-opencode-client")
        }
        if input.credential.provider == "anthropic" {
            request.setValue(sessionID, forHTTPHeaderField: "X-Claude-Code-Session-Id")
            request.setValue(Self.anthropicBetas(model: model), forHTTPHeaderField: "anthropic-beta")
        }
        let response = try await transport(request)
        try check(response)
        try Self.confirm(response.body, provider: input.credential.provider)
    }

    static func confirm(_ data: Data, provider: String) throws {
        struct Response: Decodable {
            var type: String?; var stop_reason: String?; var response: Completion?; var choices: [Choice]?; var delta: Delta?
            struct Delta: Decodable { var stop_reason: String? }
            struct Completion: Decodable { var status: String? }
            struct Choice: Decodable { var finish_reason: String? }
        }
        let decoder = JSONDecoder()
        let confirmed: Bool
        if ["openai", "opencode-go", "anthropic"].contains(provider) {
            let events = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).filter { $0.hasPrefix("data:") }
                .compactMap { try? decoder.decode(Response.self, from: Data($0.dropFirst(5).utf8)) }
            if provider != "anthropic" {
                // Go's protocol converter omits status on its response.completed event.
                confirmed = events.contains { $0.type == "response.completed" && ($0.response?.status == "completed" || provider == "opencode-go" && $0.response != nil && $0.response?.status == nil) }
                    && !events.contains { ["error", "response.failed", "response.incomplete"].contains($0.type ?? "") }
            } else {
                confirmed = events.contains { $0.type == "message_stop" }
                    && events.contains { $0.type == "message_delta" && ["end_turn", "max_tokens"].contains($0.delta?.stop_reason ?? "") }
                    && !events.contains { $0.type == "error" }
            }
        } else {
            let response = try decoder.decode(Response.self, from: data)
            confirmed = response.choices?.contains(where: { ["stop", "length"].contains($0.finish_reason ?? "") }) == true
        }
        guard confirmed else { throw Fault("warmup_unconfirmed", "Provider did not confirm the warm-up. Paused; no automatic resend.") }
    }

    // Subscription profile from MaxAnderson95/opencode-claude-auth, revision 27fcf0b.
    private static func anthropicBetas(model: String) -> String {
        var betas = ["claude-code-20250219", "oauth-2025-04-20", "interleaved-thinking-2025-05-14", "thinking-token-count-2026-05-13",
                     "context-management-2025-06-27", "prompt-caching-scope-2026-01-05", "mid-conversation-system-2026-04-07",
                     "advisor-tool-2026-03-01", "effort-2025-11-24", "fallback-credit-2026-06-01", "extended-cache-ttl-2025-04-11"]
        if model.contains("haiku") || model.contains("sonnet-4-5") { betas.removeAll { $0 == "effort-2025-11-24" } }
        return betas.joined(separator: ",")
    }

    private func request(_ credential: StoredCredential, path: String) throws -> URLRequest {
        let bases = ["anthropic": "https://api.anthropic.com/v1/", "openai": "https://chatgpt.com/backend-api/codex/",
                     "opencode-go": "https://opencode.ai/zen/go/v1/", "xai": "https://api.x.ai/v1/"]
        guard let base = bases[credential.provider], let url = URL(string: base + path) else { throw Fault("warmup_provider", "Unsupported warm-up provider.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(credential.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tally", forHTTPHeaderField: "User-Agent")
        if credential.provider == "openai" {
            request.setValue(credential.workspace, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue("opencode", forHTTPHeaderField: "originator")
        }
        if credential.provider == "anthropic" {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("oauth-2025-04-20,claude-code-20250219", forHTTPHeaderField: "anthropic-beta")
            request.setValue("cli", forHTTPHeaderField: "x-app")
            request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
            request.setValue("claude-cli/2.1.257 (external, sdk-cli)", forHTTPHeaderField: "User-Agent")
        }
        return request
    }

    private func check(_ response: ResetHTTPResponse) throws {
        guard response.status == 200 else {
            struct Failure: Decodable {
                var error: Detail?
                struct Detail: Decodable { var type: String? }
            }
            if (try? JSONDecoder().decode(Failure.self, from: response.body))?.error?.type == "RegionError" {
                throw Fault("warmup_model_region", "This model requires regional hosting opt-in in your provider settings. Choose another model or enable that region, then resume warm-up.")
            }
            throw Fault("warmup_failed", "Provider request failed (HTTP \(response.status)). Check the Account and selected model, then resume warm-up.")
        }
    }
}
