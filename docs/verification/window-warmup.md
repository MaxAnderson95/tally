# Window warm-up verification

## Read-only credential ownership

Tally opens OpenCode's database read-only. OpenCode and its auth plugins own token refresh. Every warm-up rereads the selected stored access token and performs one message request; there is no pre-send model-list request, OAuth refresh, retry, or credential write. Settings model discovery uses the stored token through a separate GET operation.

On September 12, `bash scripts/test-swift.sh` passed 85 tests; `npm --prefix web test` passed 20 tests; and `npm --prefix web run build` passed. Regression tests verify byte-for-byte preservation of a synthetic OpenCode database during model loading, reading a token changed by OpenCode after inventory collection, exactly one message request per provider, and no refresh/retry after HTTP 401 or 500. Source inspection found no OAuth refresh endpoint or `UPDATE credential` statements under `Sources`.

The app was rebuilt, signature-verified, and installed as `e9ec339-20260912142433`. The local API reported ready with seven accounts. This build includes uncommitted changes; no new provider message was sent as part of these tests.

## Direct HTTP requests

Tally sends provider requests without starting OpenCode or creating database sessions. A generated UUID supplies provider routing and cache-affinity headers only.

The Anthropic request uses streaming Messages, OAuth bearer authentication, the Claude subscription beta flags with Haiku/Sonnet 4.5 effort exclusions, a separate billing system entry with `cc_entrypoint=sdk-cli`, the plugin's system identity, and `X-Claude-Code-Session-Id`. Its subscription profile follows Max's custom plugin at revision `27fcf0b`; Tally does not import the plugin or depend on its installed path. Node/Stainless runtime headers are not copied into the Swift client.

The OpenAI request uses the Codex Responses endpoint, the selected ChatGPT workspace header, `store: false`, streaming, structured input, `session-id`, and a per-request prompt-cache key. It follows OpenCode's subscription originator and Codex's HTTP Responses body rather than launching either client. Tally identifies its HTTP user-agent as Tally.

OpenCode Go uses chat completions by default and Responses for GPT/Grok model families, following its chat-compatible default provider and OpenAI/xAI model routing. Both paths send `x-opencode-session`. The Go protocol converter can omit `status` on `response.completed`; Tally accepts this documented conversion shape only for Go Responses requests. Anthropic requires both a terminal message delta and `message_stop`; OpenAI requires a completed response. Error events prevent confirmation.

On September 12, Go Extra's `glm-5.3-flash` returned HTTP 500 for both the original and a minimal Responses request, but completed successfully through chat completions. Luna still returned HTTP 500 through chat completions with the session header present, so Tally retains Responses for that family. The corrected production sender completed a live `glm-5.3-flash` request with HTTP 200. Targeted tests cover both protocol choices and enforce one request per message. Build `e9ec339-20260912143940` was installed locally and reported ready.

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
| xAI | `grok-4.3` | HTTP 200; chat completion confirmed |

Go Extra's initial DeepSeek V4 Flash request returned HTTP 403 `RegionError`, requiring China-hosting opt-in. Its initial Luna chat-completions request returned HTTP 500; the Responses request then returned HTTP 400 `MissingSessionID`. Adding the source-backed routing header produced the successful Luna result. No region setting was changed. Production warm-up does not switch models or automatically replay failed messages.

The initial three-provider test stopped at Go's rejection. Subsequent live runs used `TALLY_WARMUP_LIVE_PROVIDER=opencode-go`, so the already successful Claude and ChatGPT messages were not repeated.

Exact live command:

```sh
TALLY_WARMUP_LIVE_SEND="$HOME/.local/share/opencode/opencode.db" bash scripts/test-swift.sh --filter warmupAuthorizedLiveMessages
```

The Go-only follow-up added `TALLY_WARMUP_LIVE_PROVIDER=opencode-go` to that command. These flags authorize real message sends and are not set in ordinary test runs. Future executions require explicit authorization for those accounts.

`bash scripts/test-swift.sh --filter warmup` passed 14 tests after the request changes on September 11. The two opt-in live tests return without network traffic in that run. Current synthetic tests cover request headers and bodies, terminal-event validation, regional errors without fallback, quota-window changes, read-only credential access, and a single message request without refresh or retry. The full suite passed 82 tests before the request-shape follow-up.

Max subsequently authorized xAI testing. `TALLY_WARMUP_LIVE_SEND="$HOME/.local/share/opencode/opencode.db" TALLY_WARMUP_LIVE_PROVIDER=xai bash scripts/test-swift.sh --filter warmupAuthorizedLiveMessages` sent a short prompt to the stored `xAI` account with `grok-4.3`. The production HTTP client returned HTTP 200 and confirmed completion. This did not send messages to the other three accounts.

xAI's `/v1/models` includes image and video generation models. Its `/v1/language-models` endpoint returned HTTP 200 and seven text-capable models using the subscription token. Tally uses that endpoint for the warm-up picker, excluding those media-generation choices without a hardcoded model-name list. The endpoint and response shape were checked against the live API and its reference:
https://docs.x.ai/developers/rest-api-reference/inference/models

Live model discovery separately returned 11 Anthropic models, 5 visible OpenAI models, and 37 Go models. Tally does not perform OAuth refresh. Live message tests establish completed inference, not the start of an idle quota window; the accounts may already have active windows. No reset credits were used. The direct HTTP and native Settings changes are published on PR #45 and installed locally; no release has been published.

## Web and mobile settings

The shared browser Settings dialog has Warm-up and Menu bar sections. Warm-up loads models automatically, groups accounts by provider, disables ineligible accounts with an upfront explanation, and uses the Mac timezone for Next warm-up, Next check, and Last checked timestamps. Model selection and enable/disable changes use the same Tally owner as native Settings. Native Settings observes preference changes made from the browser.

The additive REST routes are:

- `GET /api/v1/warmups`: cached public settings keyed by Account ID, including enabled state, selected model, nullable schedule/attempt timestamps, status, attention flag, and eligibility explanation. Private credential data and scheduler internals are excluded.
- `GET /api/v1/accounts/{id}/warmup/models`: load the provider's current models with the stored access token. Returns an array of model IDs and display names. Model discovery never refreshes credentials or writes to OpenCode.
- `PUT /api/v1/accounts/{id}/warmup`: save `{ "enabled": true, "model": "provider/model" }` and return current public settings. Existing host, origin, JSON content-type, and owner eligibility checks apply.

`bash scripts/test-swift.sh --filter 'warmup|routesEnforcePolicy'` passed 17 tests. `npm --prefix web run build` passed typechecking and bundling; `npm --prefix web test` passed 20 tests.

A temporary synthetic API served the actual built browser assets to installed headless Chrome. Interaction checks passed for automatic model fetching, model selection and save, disabled weekly-only accounts, date display, preferences after closing/reopening Settings, disabling, and rejection rollback with a visible error. The dialog and long model names fit 320px, 390px, and 1200px viewports without horizontal overflow. These checks did not send provider messages or change real preferences. Physical iPhone interaction remains a manual check.

The complete app bundle passed signature verification and was installed locally as `e9ec339-20260912031157` with the uncommitted web follow-up. The live loopback warm-up endpoint returned seven accounts, the Go Extra model route returned 37 models, and the installed JavaScript contained the new controls. The Mac could not resolve the configured tailnet hostname, so this run does not establish remote HTTPS reachability.

## Web parity audit on September 13, 2026

The browser and native app share account inventory, quota windows and pacing, extra usage/PAYG, purchased credits, banked reset details and explicit redemption/acknowledgement, icon colors, pinning and ordering, local activity ranges and breakdowns, and warm-up model selection, scheduling, and recovery. Max confirmed that launch at login, database location, listener settings, and quitting Tally remain Mac-only.

Warm-up readings are polled once for both browser account cards and Settings. Cards display failed attempts without opening Settings. Saved schedule dates remain visible when quota information is unavailable. Saving preferences invalidates older polling responses. Account settings show each stored account name with its provider, including providers with a single account.

The browser uses 44px mobile buttons and disclosure targets, a three-column mobile color picker, wrapping account names, and a scrollable Settings dialog with a sticky header. Expanded cards do not stretch adjacent cards to their detail height. The existing system typography, provider identity colors, and light/dark palettes remain in use.

Local checks:

- `bash scripts/test-swift.sh`: 86 tests passed. Live provider tests remained opt-in and did not send messages.
- `npm --prefix web test`: 20 tests passed on Node 22.22.2, matching CI's Node 22 major.
- `npm --prefix web run build`: TypeScript checking and Vite production bundling passed.
- `bash scripts/build-app.sh` and `codesign --verify --deep --strict build/Tally.app`: passed for a local bundle. This audit does not install or deploy it.
- Playwright 1.61.1 with installed headless Chrome: complete interaction checks passed at 1200px/light, 390px/light, 320px/dark, and 768px/dark. The runner served production assets and synthetic fixtures through intercepted HTTPS requests; no live API or provider requests were allowed.

Browser checks covered automatic model discovery for seven synthetic accounts, enable/model selection, disabling, failed-save rollback, model-list retry, paused-attempt Resume, the account-card warning, retained schedule dates during unavailable quota, pinning/reordering/color changes, account technical details, reset cancel/confirm/unknown acknowledgement, all activity ranges, source details, explicit provider refresh confirmation, and disconnection/recovery. Screenshots were inspected for account cards, both Settings sections, and activity; page and dialog horizontal-overflow assertions passed at every width.

The Playwright MCP server failed to start, so the audit used an already-installed local Playwright runner. No dependency was added. WebKit was not installed; Safari and physical iPhone behavior remain unverified.
