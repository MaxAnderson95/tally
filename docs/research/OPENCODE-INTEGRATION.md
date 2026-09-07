# OpenCode integration capabilities

Research for "Verify OpenCode credential, model-tool, TUI, and context-injection capabilities", 2026-09-06. This report establishes extension capabilities and open decisions; it does not select Tally's architecture or advisory policy.

https://github.com/MaxAnderson95/tally/issues/3

## Result

OpenCode V2 supports the required plugin query and redemption tools and proactive model-context advisories. A separate CLI plugin can show TUI toasts, persistent usage content, or a dedicated panel. Plugin RPC can connect the server-side collector to Tally or the TUI without exporting provider credentials.

The main unresolved capability is **exact account attribution for an outgoing model request**. Hooks expose session and model identity, but no captured credential ID. Reading the currently active connection gives a useful current selection, not proof of which account a previously resolved or subsequently rewritten request uses. Max's existing Anthropic auth plugin source resolves the connection again in its HTTP hook. Architecture must account for this before promising account-specific notices during switching. [S3, S5, S6, L2]

Direct read-only SQLite collection remains feasible and works while OpenCode is stopped, until OAuth access credentials expire. Plugin-mediated collection avoids coupling Tally to the private credential table, but `connection.resolve()` can refresh and persist credentials. It is not a read-only accessor, and existing refresh scheduling does not provide cross-process mutual exclusion. [S1, S2, L1]

Tally's API, mobile web app, and menu-bar app remain required regardless of the collection choice. OpenCode remains responsible for accounts, authentication, and refresh. Reference implementations were inspected only as evidence; Tally implementation is from scratch.

## Evidence and verification boundary

- Primary source: `anomalyco/opencode`, beta revision `b2cecc6350d377c382e1ec32ee66ec63ad68f715`, commit dated 2026-09-06. Inspected read-only at `/Users/max/.btca/agent/sandbox/opencode-beta`. No checkout or update was performed.
- Installed executable checks: `opencode2 --version` returned `opencode2 v0.0.0-beta-19192`; `opencode --version` returned `1.18.18`. They are different executables. This report targets V2. The source revision was not proven to be the exact source used to build installed beta-19192, and the running server's version was not queried.
- Fetched the official V2 plugin, CLI-plugin, RPC, and CLI guides. They agree with the main interfaces examined below. Those web pages are rolling documentation, not revision-pinned evidence.
- Prior provider endpoint responses and account inventory come from `docs/RESEARCH.md`, not new live verification. No credential database was opened, secret values read, provider requests made, refreshes triggered, or redemption attempted during this investigation.
- No applicable ADR files were found. `CONTEXT.md` supplies the domain terms.

Official guides:

https://opencode.ai/v2/docs/build/plugins

https://opencode.ai/v2/docs/build/plugins/cli

https://opencode.ai/v2/docs/build/plugins/rpc

https://opencode.ai/v2/docs/cli

## Accounts, labels, visibility, and credential access

### Supported inventory

`ctx.integration.list()` and the public integration API return integrations with `connections`. Stored connections contain `type: "credential"`, credential `id`, and user-editable `label`; environment connections contain `type: "env"` and the variable name. Secrets are absent. The credential HTTP group supports label update, activate, and delete, with no secret-read operation. [S1, S2]

`integration.list()` enumerates the current location's registered integrations, then joins globally stored credentials. A raw database inventory can therefore contain rows that this location's integration list does not expose. Environment-based connections are the reverse case: visible through the running server but absent from the credential table. MCP and other integrations also exist; do not treat every integration as an AI subscription. The TUI uses `metadata.source === "mcp"` for MCP categorization. [S2, S4]

The connection and integration schemas have **no per-account hidden/visible flag**. Provider activation (`auto`, `enabled`, `disabled`) is a separate catalog concept, and provider IDs may map to a different `integrationID`. The meaning of "OpenCode is the source of truth for visibility" needs a concrete choice: credentials shown in a selected location's connection inventory, configured model/provider availability, or another explicitly defined scope. These are not interchangeable. [S1, S2, S3, S4]

Labels are display values, not identity keys. Renaming updates the same credential ID; reconnecting creates a new ID. Explicit labels are not shown to have a uniqueness constraint. The automatically generated label only avoids collisions when no label was supplied. [S1, S2]

### Active selection

Core orders stored credentials by ascending `active`, creation time, and ID, then reverses that list. `connection.active(integrationID)` returns its first entry; stored credentials precede environment connections. This supplies a deterministic fallback even when no row has `active = true`, so testing only the database's active flag does not reproduce OpenCode selection. [S1, S2]

Activating a credential changes the integration's global selection, not one session's credential. Credential creation, switching, deletion, and label changes publish credential events. Refresh-only value updates do not publish `credential.updated`. The database does not store a separate account-selection record per session. [S1, S5]

### Collection options

| Option | What it enables | Cost or limit |
|---|---|---|
| Tally reads credential SQLite rows read-only | Independent polling when OpenCode has no running server; all stored credential rows and provider-specific metadata | Private schema/path coupling; does not see environment connections or location registry transforms; must reproduce selection ordering if needed; cannot refresh expired tokens |
| Server plugin enumerates connections and resolves each one | Public plugin access to values, including inactive stored accounts; OpenCode performs provider-specific refresh; plugin can publish normalized results instead of tokens | Needs a live plugin instance in an appropriate location; resolve can perform network requests and DB writes; concurrent callers can race refresh |
| Read-only collector plus model/TUI adapter plugin | Independent collection and required tools/context/TUI extension points can coexist | Two lifecycle domains and attribution synchronization remain; this is a possible combination, not an architecture decision |

The credential table still has `id`, `integration_id`, `label`, JSON `value`, `connector_id`, `method_id`, nullable `active`, and timestamps. SQLite uses WAL in core. The prior machine path in `docs/RESEARCH.md` remains prior observed evidence, not a universal database-discovery contract. A reader must tolerate unavailable files, migration/schema changes, and replaced credentials without initiating migrations itself. [S1, S11]

### Refresh implications

`resolve(connection)` reads the credential by ID, returns keys immediately, and for OAuth looks up the registered method's refresh implementation. With no implementation it returns the stored value, even if expired. With an implementation, it refreshes when expiry is at or before now plus five minutes, writes the returned value, and returns it. The path has no visible credential-scoped semaphore or database compare-and-swap around the read/network/write sequence. It accepts inactive connections; it does not activate them. [S2]

The current `token-refresh` plugin resolves connections every two minutes plus up to one minute of jitter. Its module-level loop borrows one attached location context, stops when none remain, and skips environment connections. It backs off individual failures from 15 minutes up to six hours. Jitter lowers collision probability but is not a lock across server processes or other request-time resolvers. Its "refreshed" log detection is a timing/expiry heuristic. Logs are diagnostic evidence, not an authoritative machine-readable health API. [L1]

Consequences:

- A plugin collector calling `resolve()` adds another refresh-triggering caller. Keeping ownership in OpenCode does not itself establish single-flight refresh.
- A missing refresh implementation, absent plugin instance, transient provider failure, expiry, and confirmed refresh-token rejection are different states. An expired access token alone does not prove the user must reconnect.
- `expires: 0` is not generically treated as "never expires" by `resolve()`. It returns unchanged if no refresh implementation exists; otherwise zero is already due. Provider-specific behavior matters.
- The scheduler only sees the borrowed context's integration inventory. "Every stored credential" is too broad when an integration exists only in another location or is no longer registered.

## Request and session attribution

The model resolver maps provider to integration, reads its current connection, resolves a credential, and builds the runtime model. The returned resolved-model object carries model reference/capabilities/cost/limits, but no connection ID. The context and request hooks consume that already resolved model. [S3, S5]

| Boundary | Exposed identity | Attribution limitation |
|---|---|---|
| `session.hook("context")` | `sessionID`, agent, model/provider/variant | No credential ID, physical request ID, message ID, or request kind |
| `model.request` | Same plus `kind` and request URL/header overrides | No captured credential ID; headers are request overrides, not a guaranteed final authentication snapshot |
| `http.request` / `http.response` | Session/model/agent, `kind`, native Request/Response | Can inspect the actual request at this hook position, but other hooks can rewrite it later; no standardized account field |
| Tool execution | Session, agent, message ID, tool call ID | No originating request's credential or model field in tool context |
| `credential.switched` | Integration ID and selected credential ID | Current selection event, not a historical request-to-account association |

Native HTTP hooks distinguish `primary`, `compaction`, `title`, and `generate`. Context hooks lack `kind`; compaction can present the selected session agent there. The title path explicitly disables context hooks. The context hook is therefore suitable for repeated request-time guidance but cannot reliably filter every auxiliary request using a request-kind field that it does not have. [S5, S6]

The current OpenAI provider plugin caches ChatGPT metadata, adds `chatgpt-account-id` in its catalog transform, and reloads on credential switches. Max's Anthropic plugin reads and resolves the active connection again in `http.request`, then rewrites the authentication header. A context-time selection can differ from that later selection. This is a concrete reason to avoid describing `connection.active()` as exact request attribution. [S3, L2]

A header-based attribution experiment could compare an in-memory credential-derived fingerprint or provider account header without exporting secrets. It would still need to prove hook ordering, retries, provider overrides, and token rotation behavior. In current core, merely installing an HTTP hook also disables the session WebSocket transport path for eligible Responses models. That is a material tradeoff, not a free observation hook. No such experiment was run. [S5]

For exact attribution, evidence is still needed for a stable connection snapshot carried into the context hook, or an equivalent provider-specific observation proven across all supported request paths. Until then, distinguish "currently selected account" from "account used by this request", and mark unknown attribution rather than attaching another account's exhausted window to a session.

## Required model tools and proactive advisories

### Query and redemption tools

`ctx.tool.transform(editor => editor.add(...))` supports named tools with input/output schemas, descriptions, asynchronous execution, structured output or text content, optional namespace, Code Mode options, and a permission name. Tool context has stable session/message/tool-call identifiers. This is sufficient to expose Tally query and redemption operations through a server plugin, whether their implementation calls Tally's API or an in-process collector. Tool registration supplies capability; it does not verify the provider redemption endpoint or its eligibility semantics. [S7]

The query tool can report account names and IDs, window applicability, remaining percentages, resets, freshness/errors, and banked-reset availability separately from eligibility. The redemption tool can target a specific account rather than silently reinterpreting "active" after a user switches. The exact contract, authorization semantics, and handling of uncertain mutation outcomes belong to later architecture/redemption decisions.

OpenCode's message and tool-call IDs can correlate invocations, but they do not provide provider-side redemption idempotency. Retrying a tool or losing a response after a successful provider mutation needs an explicit outcome/reconciliation policy. No provider mutation was performed here.

Register tools through the tool registry. Adding a novel tool only to a context hook's `event.tools` is insufficient: core drops definitions that cannot be matched to a registered executable. Each prepared model request captures its tool capability; subsequent registry changes affect later requests. [S5, S7]

### Context injection

`ctx.session.hook("context", callback)` can append text to `event.system` immediately before request preparation. This affects outgoing context without adding durable session history. It runs on subsequent model calls, including tool continuations, so a model need not proactively query Tally to receive guidance. [S5, S6]

This meets the advisory mechanism requirement: carry low-quota facts and encourage wrapping up and a user-directed switch to a suitable second account. No interruption, model switch, tool removal, retry override, or generation limit is necessary. A background poll cannot edit a model request already in flight; context guidance arrives at a later call. TUI notification can happen independently while a request is running.

The accepted signal is 25%, 10%, and 5% remaining in the shortest-duration applicable quota window, plus exhaustion of other applicable windows. OpenCode's model reference supplies part of the applicability input; Tally still needs provider-specific window/model/plan mappings and actual duration data. Do not select the window whose reset happens soonest. A candidate second account needs applicable capacity and suitable model access, not merely a larger percentage in a different bucket.

Hooks run in registration order and core awaits each callback. There is no blanket exception swallowing at the hook dispatcher. Collector timeouts or plugin exceptions must not turn advisory delivery into a request failure. A later implementation needs a bounded/failure-tolerant snapshot read; this report does not select cache freshness or suppression policy. [S6]

## TUI notifications and exploratory display

The CLI plugin context has `ui.toast.show({ title?, message, variant?, duration? })`. `attention.notify(...)` separately supports system notification and configured sound with focus conditions; it reports skipped states such as disabled attention or unknown focus. A toast is client-local UI, not a server-wide model message. [S8]

Optional display surfaces are supported in the typed slot map: `prompt.footer.status`, `session.composer.top`, `sidebar.content`, `sidebar.footer`, and `session.panel`, among others. Session-specific slots receive `sessionID`. Routes, commands, dialogs, and panel presentation controls are available. These are feasible extension points for an exploratory usage display, without requiring Tally to choose a layout now. [S8]

Server plugins do not receive the CLI UI context. They can emit a custom RPC event and expose a snapshot method; a CLI plugin uses `context.client.rpc(...)` against its connected server, then shows the toast or renders content. RPC events include location and are live-only, so disconnected clients miss events and need a fresh snapshot after connecting. Core returns `rpc.unavailable` for a missing registration and validates method input/output. [S9]

A package can export both the server entrypoint and `./tui`; CLI-only packages can be configured in global `cli.json`, including when connected to remote servers. Actual local config placement was outside this read-only investigation; no config changes or assumptions about currently enabled plugin instances were made.

## Lifecycle and duplicate-delivery evidence

- **Shared server:** local clients normally use one managed service. Closing a TUI is not equivalent to stopping that service. Server plugins are location-scoped, so a global plugin definition can produce multiple instances as locations load. [S10, S12]
- **Standalone:** `--standalone` launches a private child server with generated Basic-auth credentials and a stdin ownership lease; EOF ends that lease. The child inherits the environment. A private server is not evidence of a separate credential database. Concurrent standalone and shared processes require cross-process reasoning. [S10]
- **Explicit/remote server:** the CLI connects to the selected server and health-checks it. A local DB reader does not automatically read the remote server's credentials; UI account and collector identity must be bound to the same OpenCode authority. Explicit-server version mismatch currently warns and continues; managed connection mismatch handling can also ignore version differences. [S10]
- **No server:** a DB reader can still use unexpired stored tokens; a plugin-only collector and model advisories cannot run. No TUI means no TUI toast. Tally's independently hosted surfaces still need a defined stale/unavailable state.
- **Multiple TUIs:** each has its own UI plugin and may receive the same event. Receiving a server event does not establish that its session is the foreground tab. CLI route/slot state can identify the displayed session; choosing which client should alert is a later policy decision. [S8, S9]

Core plugin storage is persistent global KV namespaced by plugin ID, not location. It supports get/set/remove/scan, without compare-and-swap or an atomic claim operation. It can persist advisory state, but a read-then-set sequence cannot promise exactly-once delivery across concurrent plugin instances/processes. [S12]

TUI durable storage uses a file lock, reloads the latest JSON before mutation, writes atomically, and watches for changes. It synchronizes same-host/channel TUI instances; it is not distributed state across remote hosts or a transaction with notification delivery. Memory storage survives plugin reload only until that TUI exits. [S8]

Evidence required before final deduplication design:

1. Stable account identity, including reauth/replacement and duplicate Zen/Go credential rows. Do not use mutable labels or rotating access-token hashes as the sole logical account key.
2. Window identity, applicability scope, duration, reset-cycle identity, observation time, and threshold/exhaustion reason. The same percentage in a new quota cycle is a new condition.
3. Session/model/selected-account association with an explicit certainty level. Switching accounts, changing models, child sessions, and auxiliary calls can change applicability.
4. The chosen ownership scope for crossing detection and delivery state: account-wide versus session-specific versus per-TUI. Model guidance and human notification need separate delivery accounting if one should repeat and the other should not.
5. A concurrency mechanism if more than one actor can claim delivery. KV persistence and jitter alone do not establish this.
6. Reconnect/restart behavior, whether to notify on an initial already-low snapshot, and what happens when sampling jumps over several thresholds. These are policy questions, not missing OpenCode rendering capabilities.

## Corrections and qualifications to docs/RESEARCH.md

| Earlier claim | Current finding |
|---|---|
| V2 credentials are SQLite rows; HTTP inventory omits secrets | Confirmed in source. No new live DB inspection. |
| Direct DB is the only external path to a token | No built-in credential-secret read endpoint was found. A custom server plugin can resolve values and implement RPC; prefer exporting normalized usage rather than treating secret export as necessary. |
| `resolve()` is only ever called for active credentials at request time | Too strong. It accepts any stored connection, and core provider setup/load paths also call it. The existing scheduler explicitly resolves inactive accounts. |
| The refresh plugin closes the freshness gap | It improves freshness while attached and healthy. It is not a cross-process lock or proof every DB row is covered. |
| Expired access means reauthentication is needed | Expiry can also mean OpenCode was stopped, no refresh method was present, or refresh failed transiently. Reauthentication is not proven by expiry alone. |
| API auth is `$OPENCODE_SERVER_PASSWORD` | Basic auth remains supported. Current CLI prefers `OPENCODE_PASSWORD` and honors the old name as fallback; standalone generates a password, managed service uses its own endpoint auth. Server core also permits configurations without a password. |
| Active database flag identifies the account | It identifies selection when populated, but OpenCode applies ordering/fallback and provider-to-integration mapping. It does not establish historical request attribution. |
| Zen/Go keys are duplicates; provider endpoints worked | Remains prior live evidence only. No endpoint or key comparison was repeated. Cross-integration account identity/name policy remains to settle. |

## Concrete gaps for architecture and advisory grilling

1. Define OpenCode-derived account visibility and the authoritative location/server when multiple inventories exist.
2. Choose the collection boundary while preserving OpenCode refresh ownership and defining behavior when no server is running.
3. Decide whether selected-account attribution is sufficient, or whether exact captured request attribution requires an upstream extension/prototype. The current generic hook contract does not supply it.
4. Resolve Zen/Go alias identity and conflicting labels without exposing credentials or making token rotation change logical identity.
5. Decide deduplication scope, reset-cycle handling, stale-data policy, and separation of model context from TUI notices.
6. Validate query/redemption contracts and provider eligibility/idempotency separately; OpenCode tool registration is feasible, provider mutation semantics are not established here.
7. Pin a minimum tested OpenCode/plugin release and test installed packages against it. Source-current feasibility does not prove beta-19192 runtime compatibility, especially for newer context/request-kind/panel APIs.

## Source references

All `S` paths below are relative to the pinned OpenCode checkout. Line ranges were read directly. Each group includes a pinned upstream URL for navigation; sibling file paths/ranges use the same revision.

- **S1: Credential persistence and public shape.** `packages/core/src/credential/sql.ts:5-14`; `packages/core/src/credential.ts:26-51,78-94,99-228`; `packages/schema/src/connection.ts:6-21`; `packages/protocol/src/groups/credential.ts:6-53`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/credential.ts#L78-L228

- **S2: Inventory, ordering, labels, resolution/refresh.** `packages/core/src/integration.ts:334-367,648-684`; `packages/schema/src/integration.ts:58-72`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/integration.ts#L648-L684

- **S3: Model credential selection and provider-specific state.** `packages/core/src/model-resolver.ts:271-299`; `packages/schema/src/provider.ts:28,51-53`; `packages/core/src/plugin/provider/openai.ts:229-310,332-345`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/model-resolver.ts#L271-L299

- **S4: TUI integration inventory.** `packages/tui/src/component/dialog-integration.tsx:47-73,75-127`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/tui/src/component/dialog-integration.tsx#L47-L127

- **S5: Request preparation and identity.** `packages/core/src/session/model-request.ts:198-269,290-369`; `packages/plugin/src/promise/session.ts:13-83`; `packages/core/src/session/title.ts:67-73`. Session schema search found no credential/account selection field.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/session/model-request.ts#L290-L369

- **S6: Hook execution.** `packages/core/src/plugin/hooks.ts:69-112`; `packages/plugin/src/promise/session.ts:21-83`. Repeated context semantics and compaction agent behavior are also documented in the official plugin guide's Model context section.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/plugin/hooks.ts#L69-L112

- **S7: Tool contracts.** `packages/plugin/src/promise/tool.ts:11-34,37-69`; `packages/schema/src/tool.ts:14-44,86-102`; `packages/core/src/tool.ts:220-225`; executable pairing in S5.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/schema/src/tool.ts#L14-L44

- **S8: CLI UI and storage.** `packages/plugin/src/tui/context.ts:154-201,270-322,460-514`; `packages/tui/src/context/storage.tsx:18-30,47-125`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/tui/src/context/storage.tsx#L47-L125

- **S9: Plugin RPC.** `packages/core/src/rpc.ts:67-164`; official RPC guide's Subscribe section establishes live-only external delivery and location filtering.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/rpc.ts#L67-L164

- **S10: Server connections/auth/lifecycle.** `packages/cli/src/services/server-connection.ts:21-83`; `packages/cli/src/services/standalone.ts:16-56`; `packages/cli/src/env.ts:7-13`; `packages/server/src/auth.ts:15-34`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/cli/src/services/server-connection.ts#L21-L83

- **S11: Database runtime.** `packages/core/src/database/database.ts:31-38` enables WAL; filesystem/injected-client database variants are documented in that file. The machine-specific file path remains evidence from `docs/RESEARCH.md:21-58`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/database/database.ts#L31-L38

- **S12: Plugin lifetime and durable storage.** `packages/core/src/plugin.ts:47-86,296` (location node); `packages/core/src/plugin/host.ts:561-587`; `packages/core/src/kv.ts:27-31,39-59,92`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/plugin/host.ts#L561-L587

- **L1: Existing refresh scheduler.** `/Users/max/my-opencode-setup`, HEAD `9d0c08de48e4a669611a2b4d5f92756d9f83065b`; `plugins/token-refresh/token-refresh.ts:8-44`, `lib/loop.ts:21-53`, `lib/refresher.ts:24-30,61-105`. These files were clean in the observed worktree; unrelated changes were left untouched.
- **L2: Existing Anthropic auth adapter.** `/Users/max/Projects_personal/opencode-claude-auth`, HEAD `414d3ba887636ed253fbdd5b7ba2a411b59349eb`; read working-tree `src/v2-setup.ts:82-120,139-190`. This is a local source observation, not a verified inventory of the plugin package currently loaded by the running server.

Verification completed: source/contract inspection, official-guide retrieval, revision checks, and both executable version commands. No runtime extension test or end-to-end advisory/redemption test was performed.
