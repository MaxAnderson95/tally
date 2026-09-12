# Window warm-up verification

## Direct HTTP requests

Tally sends provider requests without starting OpenCode or creating database sessions. A generated UUID supplies provider routing and cache-affinity headers only.

The Anthropic request uses streaming Messages, OAuth bearer authentication, the Claude subscription beta flags with Haiku/Sonnet 4.5 effort exclusions, a separate billing system entry with `cc_entrypoint=sdk-cli`, the plugin's system identity, and `X-Claude-Code-Session-Id`. Its subscription profile follows Max's custom plugin at revision `27fcf0b`; Tally does not import the plugin or depend on its installed path. Node/Stainless runtime headers are not copied into the Swift client.

The OpenAI request uses the Codex Responses endpoint, the selected ChatGPT workspace header, `store: false`, streaming, structured input, `session-id`, and a per-request prompt-cache key. It follows OpenCode's subscription originator and Codex's HTTP Responses body rather than launching either client. Tally identifies its HTTP user-agent as Tally.

OpenCode Go uses its Responses endpoint and requires `x-opencode-session`. The Go protocol converter can omit `status` on `response.completed`; Tally accepts this documented conversion shape only for Go. Anthropic requires both a terminal message delta and `message_stop`; OpenAI requires a completed response. Error events prevent confirmation.

Source references:

- Custom Claude subscription headers, beta configuration, billing entrypoint, and system transforms:
https://github.com/MaxAnderson95/opencode-claude-auth/tree/27fcf0b/src
- OpenCode's OpenAI subscription routing and headers:
https://github.com/anomalyco/opencode/blob/0f26ad878/packages/core/src/plugin/provider/openai.ts
- OpenCode's outgoing session headers:
https://github.com/anomalyco/opencode/blob/0f26ad878/packages/core/src/session/model-request.ts
- Codex Responses body and session headers, inspected through the local BTCA clone:
https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/common.rs
https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/requests/headers.rs
- Go's Responses route and protocol conversion:
https://github.com/anomalyco/opencode/blob/0f26ad878/packages/console/app/src/routes/zen/go/v1/responses.ts
https://github.com/anomalyco/opencode/blob/0f26ad878/packages/console/app/src/routes/zen/util/provider/openai.ts

## Live verification on September 11, 2026

Max authorized message testing on precisely these accounts. The opt-in `warmupAuthorizedLiveMessages` test used the production Swift `ProviderWarmup` and `SingleSendHTTP` implementation, loaded each selected account from OpenCode's database, fetched its model list, and sent one short arithmetic prompt per successful case.

| Account | Model | Observed result |
| --- | --- | --- |
| Claude Personal | `claude-haiku-4-5-20251001` | HTTP 200; terminal message delta and message stop confirmed |
| ChatGPT Work | `gpt-5.6-luna` | HTTP 200; completed Responses event confirmed |
| OpenCode Go Extra | `gpt-5.6-luna` | HTTP 200; completed Responses event confirmed |

Go Extra's initial DeepSeek V4 Flash request returned HTTP 403 `RegionError`, requiring China-hosting opt-in. Its initial Luna chat-completions request returned HTTP 500; the Responses request then returned HTTP 400 `MissingSessionID`. Adding the source-backed routing header produced the successful Luna result. No region setting was changed. Production warm-up does not switch models or automatically replay failed messages.

The initial three-provider test stopped at Go's rejection. Subsequent live runs used `TALLY_WARMUP_LIVE_PROVIDER=opencode-go`, so the already successful Claude and ChatGPT messages were not repeated.

Exact live command:

```sh
TALLY_WARMUP_LIVE_SEND="$HOME/.local/share/opencode/opencode.db" bash scripts/test-swift.sh --filter warmupAuthorizedLiveMessages
```

The Go-only follow-up added `TALLY_WARMUP_LIVE_PROVIDER=opencode-go` to that command. These flags authorize real message sends and are not set in ordinary test runs. Future executions require explicit authorization for those accounts.

`bash scripts/test-swift.sh --filter warmup` passed 14 tests after the request changes. The two opt-in live tests return without network traffic in that run. Synthetic tests cover request headers and bodies, terminal-event validation, regional errors without fallback, quota-window changes, and refresh success or suspension after one retry. The full suite passed 82 tests before this request-shape follow-up.

Live model discovery separately returned 11 Anthropic models, 5 visible OpenAI models, 37 Go models, and 12 xAI models. xAI message sending and live OAuth refresh are not verified. Live message tests establish completed inference, not the start of an idle quota window; the accounts may already have active windows. No reset credits were used. Changes have not been installed or published.
