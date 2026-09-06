# Research: reading AI subscription usage through OpenCode 2 credentials

Findings from a viability spike on 2026-09-06 (OpenCode session `ses_f88b35664ffejzbO6BvsXp7Ttz`). Everything below was verified against OpenCode 2 `beta-19135` and `beta-19192` source (`anomalyco/opencode`, branch `beta`, local clone at `~/.btca/agent/sandbox/opencode-beta`) and against live responses from every provider endpoint listed, using Max's real accounts.

## The idea

OpenUsage (the current menu-bar app) reads credentials from the Claude and Codex CLIs, which Max does not use. OpenCode 2 already holds OAuth credentials for every subscription Max cares about, including more than one account per provider. A usage tracker can read those credentials and call the same usage endpoints OpenUsage calls, with no login flow of its own.

Verdict by provider:

| Provider | Viable | Signal available |
|---|---|---|
| Anthropic (Claude Max, 2 accounts) | Yes | 5h and 7d percent with resets, per-model weekly buckets, extra-usage spend |
| OpenAI (ChatGPT Plus + Business, 2 accounts) | Yes | percent per plan-defined window with resets, credits |
| OpenCode Zen/Go (2 accounts) | Yes | rolling, weekly, monthly percent with resets |
| xAI (Grok) | Yes | weekly pool percent with reset, pay-as-you-go cap |
| GitHub Copilot (Enterprise, org-pooled) | **No** | the OpenCode-stored token is `read:user` only and per-seat quota does not exist on this plan; pooled usage needs an org-admin token and even then has no percentage (details below) |

8 of 10 stored credentials returned live usage on the first attempt; the other 2 were expired tokens (now handled, see "Token freshness") and were verified after refresh.

## Where OpenCode 2 stores credentials

Not `auth.json` (that file is a v1 leftover). Credentials live in SQLite:

```
~/.local/share/opencode/opencode.db      # 8.7 GB, WAL mode; open read-only
table: credential
```

Schema (`packages/core/src/credential/sql.ts`):

| Column | Meaning |
|---|---|
| `id` | `cred_...` |
| `integration_id` | provider id: `anthropic`, `openai`, `github-copilot`, `xai`, `opencode`, `opencode-go`, or `mcp_<hash>` for MCP servers |
| `label` | user-facing account name, e.g. `Work`, `Personal`, `default`, `Primary`, `Extra` |
| `value` | JSON, see below |
| `active` | 1 for the account OpenCode currently uses for that provider; 0 or NULL otherwise |
| `connector_id`, `method_id` | NULL in practice; the method id lives inside `value` |
| `time_created`, `time_updated` | epoch ms |

`value` is a tagged union (`packages/schema/src/credential.ts`):

```jsonc
{ "type": "oauth", "methodID": "claude-subscription", "access": "...", "refresh": "...", "expires": 1788735134667, "metadata": { ... } }
{ "type": "key",   "key": "sk-..." }
```

`expires` is epoch ms. `metadata` is provider-specific; OpenAI stores `{ "accountID": "<uuid>" }`, which the usage endpoint needs.

Read it read-only:

```sh
sqlite3 "file:$HOME/.local/share/opencode/opencode.db?mode=ro" "select ..."
```
```ts
new Database(path, { readonly: true })   // bun:sqlite
```

Skip `integration_id LIKE 'mcp_%'` rows; they are MCP server OAuth tokens, not subscriptions.

### Current inventory on this machine

| integration | label | type | notes |
|---|---|---|---|
| anthropic | Work (active), Personal | oauth, method `claude-subscription` | tokens last 8h; refresh registered by Max's `opencode-claude-auth` plugin |
| openai | Work (active), Personal | oauth, method `chatgpt-browser` | tokens last ~10 days; `metadata.accountID` present |
| github-copilot | default | oauth, method `device` | `expires: 0`; the GitHub token never expires; scope `read:user` only |
| xai | default | oauth, method `device` | tokens last 6h |
| opencode | Primary (active), Extra | key | Zen keys |
| opencode-go | Extra (active), Primary | key | **the same two keys as `opencode`** (`opencode/Primary` = `opencode-go/Primary`, `opencode/Extra` = `opencode-go/Extra`); dedupe by key, not by row |

## What is not available

The OpenCode HTTP API never returns secrets. `GET /api/integration` lists connections as `{type:"credential", id, label}` only (`packages/schema/src/connection.ts`), and `/api/credential/:id` supports only label update, activate, and delete (`packages/protocol/src/groups/credential.ts`). Reading the SQLite table directly is the only external path to a token. (A plugin running inside the server can call `ctx.integration.connection.resolve()`, but that is what the `token-refresh` plugin already does; the usage tracker does not need to be a plugin.)

The local server also requires HTTP Basic auth (`opencode:$OPENCODE_SERVER_PASSWORD`, `packages/server/src/auth.ts`) if the tracker ever talks to it.

## Usage endpoints

Headers copied from OpenUsage's Swift clients (`~/.btca/agent/sandbox/openusage/Sources/OpenUsage/Providers/*`), then verified live. Response shapes below are from real responses; only observed fields are listed.

### Anthropic (Claude Pro/Max)

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <access>
anthropic-beta: oauth-2025-04-20
Accept: application/json
User-Agent: claude-code/2.1.69      # sent by OpenUsage; not tested without it
```

Response (200):

```jsonc
{
  "five_hour":  { "utilization": 8, "resets_at": "2026-09-06T20:09:59.739061+00:00", "limit_dollars": null, "used_dollars": null, "remaining_dollars": null, "locked_reason": null },
  "seven_day":  { "utilization": 5, "resets_at": "2026-09-07T04:59:59.739090+00:00", ... },
  "seven_day_opus": null, "seven_day_sonnet": null,          // per-model buckets, null when not applicable
  "extra_usage": { "is_enabled": true, "monthly_limit": null, "used_credits": 0, "utilization": null, "currency": "USD", "decimal_places": 2, ... },
  "limits": [                                                 // newer, structured view of the same data
    { "kind": "session",       "group": "session", "percent": 8,  "severity": "normal", "resets_at": "...", "scope": null, "is_active": false },
    { "kind": "weekly_all",    "group": "weekly",  "percent": 5,  "severity": "normal", "resets_at": "...", "scope": null, "is_active": false },
    { "kind": "weekly_scoped", "group": "weekly",  "percent": 10, "severity": "normal", "resets_at": "...", "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null }, "is_active": true }
  ],
  "spend": { "used": { "amount_minor": 0, "currency": "USD", "exponent": 2 }, "limit": null, "percent": 0, "severity": "normal", "enabled": true, ... }
}
```

Several other top-level keys carry internal codenames (`nimbus_quill`, `tangelo`, ...) and are null or zero; ignore them. `utilization` is a percent. An expired access token returns 401.

### OpenAI (ChatGPT Plus / Business, used by Codex)

```
GET https://chatgpt.com/backend-api/wham/usage
Authorization: Bearer <access>
ChatGPT-Account-Id: <metadata.accountID>     # selects the workspace; required for multi-account
Accept: application/json
```

Response (200), Personal (Plus):

```jsonc
{
  "user_id": "user-...", "account_id": "<uuid>", "email": "...", "plan_type": "plus",
  "rate_limit": {
    "allowed": true, "limit_reached": false,
    "primary_window":   { "used_percent": 0,  "limit_window_seconds": 18000,  "reset_after_seconds": 9431,  "reset_at": 1788717645 },   // 5h
    "secondary_window": { "used_percent": 33, "limit_window_seconds": 604800, "reset_after_seconds": 67444, "reset_at": 1788775658 }    // 7d
  },
  "additional_rate_limits": [ { "limit_name": "gpt-reserve", "metered_feature": "base_model_inference", "rate_limit": { ... }, "normal_model_slug": "gpt-5.6-luna" } ],
  "credits": { "has_credits": false, "unlimited": false, "overage_limit_reached": false, "balance": "0", ... },
  "rate_limit_reset_credits": { "available_count": 3, "applicable_available_count": 0 }
}
```

Work (`plan_type: "self_serve_business_prolite"`) had a single weekly `primary_window` (`limit_window_seconds: 604800`) with `used_percent: 100`, `limit_reached: true`, and `secondary_window: null`. Window semantics differ per plan; read `limit_window_seconds` rather than assuming which window is which. `reset_at` is epoch seconds.

OpenUsage also calls `https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` for credit expiry details (not tested).

### GitHub Copilot

```
GET https://api.github.com/copilot_internal/user
Authorization: token <access>               # "token" scheme, not Bearer
Accept: application/json
Editor-Version: vscode/1.96.2
Editor-Plugin-Version: copilot-chat/0.26.7
User-Agent: GitHubCopilotChat/0.26.7
X-Github-Api-Version: 2025-04-01
```

Response (200), enterprise seat:

```jsonc
{
  "login": "...", "copilot_plan": "enterprise", "access_type_sku": "copilot_enterprise_seat_quota",
  "quota_reset_date": "2026-10-01",
  "quota_snapshots": {
    "chat":                 { "unlimited": true,  "percent_remaining": 100, "entitlement": 0, "remaining": 0, "overage_permitted": false, "timestamp_utc": "..." },
    "completions":          { "unlimited": true,  ... },
    "premium_interactions": { "unlimited": ...,   "percent_remaining": 100, "overage_permitted": true, ... }
  },
  "organization_list": [ { "login": "...", "name": "..." } ]
}
```

**Non-viable for this setup.** Max's seat is Copilot Enterprise managed by the `gucu-engineers` org, billed on GitHub's token-based model (`token_based_billing: true`) with usage pooled across the org. The user-scoped endpoint above reports every bucket as `unlimited: true` with `entitlement`/`remaining` of 0, because per-seat quota does not exist on this plan; the pooled usage lives in *organization* billing, which this endpoint never carries.

The org-level data exists but is out of reach of the OpenCode-stored token:

- `GET https://api.github.com/orgs/{org}/settings/billing/usage/summary` (public REST, `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`) returns month-to-date `usageItems[]`; the Copilot pool is the item with `product: "Copilot"`, `sku: "copilot_ai_unit"`, `unitType: "ai-units"`. Observed on 2026-09-06: `grossQuantity: 336.42` units consumed, `discountQuantity: 336.42` (covered by the plan), `netAmount: 0` (no overage). `/orgs/{org}/settings/billing/premium_request/usage` returned an empty `usageItems` for this org.
- Reading it requires org owner or billing manager and a token with `read:org`. Max is `role: admin` in `gucu-engineers`, so his `gh` work login works. The Copilot device-flow token OpenCode stores carries only `read:user` (`x-oauth-scopes` header): `/user/orgs` returns 403 and the billing endpoints return 404. Using it is not an option, and the tracker has no other GitHub credential unless one is provisioned specifically for it (a PAT or the `gh` token), which breaks the "piggyback on OpenCode" premise.
- Even with access, no endpoint found exposes the size of the included pool. `/orgs/{org}/copilot/billing` gives seats and plan type only. The best available rendering is what OpenUsage does: a raw "Org Credits" count plus "Org Spend" dollars, with `netAmount > 0` as the "into overage" signal. No percentage.

If a GitHub credential is ever added to the tracker, the OpenUsage implementation to copy is `CopilotOrgBillingClient.swift` + `CopilotOrgBillingMapper.swift` (probe `/user/orgs`, try each org's billing summary, remember the first that has Copilot AI-unit items).

### OpenCode Zen and Go

```
GET https://opencode.ai/zen/go/v1/usage
Authorization: Bearer <key>
Accept: application/json
```

Response (200):

```jsonc
{ "usage": {
  "rolling": { "status": "ok", "percent": 0,  "resetsAt": "2026-09-06T20:23:36.301Z" },
  "weekly":  { "status": "ok", "percent": 53, "resetsAt": "2026-09-07T00:00:00.301Z" },
  "monthly": { "status": "ok", "percent": 26, "resetsAt": "2026-10-03T01:07:51.301Z" }
} }
```

Both `opencode` and `opencode-go` rows work against this endpoint with the same key. Two distinct keys, two accounts; the four rows are duplicates.

### xAI (Grok)

```
GET https://cli-chat-proxy.grok.com/v1/billing?format=credits      # weekly shared pool
GET https://cli-chat-proxy.grok.com/v1/settings                     # OpenUsage also reads this
Authorization: Bearer <access>
X-XAI-Token-Auth: xai-grok-cli
Accept: application/json
```

Verified live (2026-09-06, after Max re-authenticated). Response (200) from the billing endpoint:

```jsonc
{ "config": {
  "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY", "start": "2026-09-05T13:45:37.894507+00:00", "end": "2026-09-12T13:45:37.894507+00:00" },
  "onDemandCap":  { "val": 0 },          // pay-as-you-go cap; 0 = disabled
  "onDemandUsed": { "val": 0 },
  "prepaidBalance": { "val": 0 },
  "isUnifiedBillingUser": true,
  "topUpMethod": "TOP_UP_METHOD_SAVED_PAYMENT_METHOD",
  "billingPeriodStart": "...", "billingPeriodEnd": "..."
} }
```

The payload is a proto3 message serialized as JSON, so **zero-valued fields are omitted**. The weekly pool percentage is `config.creditUsagePercent` (a number, observed by OpenUsage as e.g. `99.0`); it is absent above because usage was 0% at the time, not because the field went away. Treat a missing `creditUsagePercent` as 0 and a present non-numeric one as a schema change. Only `USAGE_PERIOD_TYPE_WEEKLY` periods carry the pool; accounts still on the legacy monthly period have no weekly meter. Decoder to mirror: OpenUsage's `GrokCreditsConfigDecoder.swift`.

`/v1/settings` returned 200 with CLI configuration (default model `grok-4.6`, announcements, feature flags) and nothing about usage; OpenUsage reads it only for the plan name, which did not appear in this response.

Tokens last 6h; the refresh endpoint is `https://auth.x.ai/oauth2/token` (core's `xai.ts` handles it).

## Token freshness

Core refreshes an OAuth credential only inside `Integration.connection.resolve()` (`packages/core/src/integration.ts:667-685`): when under 5 minutes remain it calls the method's registered `refresh`, writes the new value to the `credential` table, and returns it. `resolve()` is only ever called for a provider's *active* connection, at request time. Inactive accounts (Anthropic Personal, OpenAI Personal here) therefore rot until you switch to them.

That gap is closed by the `token-refresh` plugin (`~/my-opencode-setup/plugins/token-refresh`, commit `9d0c08d`), which resolves every stored credential every 2-3 minutes from inside each running OpenCode server. Consequences for the tracker:

- **Read only. Never refresh.** Refreshing from outside races OpenCode on rotating refresh tokens. Read `access`, use it, and treat `expires < now` as "reauth needed in OpenCode", not as something to fix.
- With the plugin running, a token is stale only when its refresh token is dead (e.g. OpenAI Work returned 401 on refresh on 2026-09-06 and had to be reconnected) or when no OpenCode server has run for longer than the token lifetime. Both are user-visible states worth showing.
- The plugin logs to `~/.local/share/opencode/token-refresh.log` (`refreshed`, `failed ... : Request failed: 401`, `recovered`); the tracker could surface `failed` lines as the reason a token is stale.
- Copilot (`expires: 0`) and Zen keys never expire.

## Pitfalls seen

- `sqlite3 -json` and `json_extract(value, '$.expires')` work fine; the DB is large but the `credential` table is tiny.
- Anthropic and OpenAI both rotate refresh tokens on refresh. xAI accepted a reused refresh token during the spike, so behavior is provider-specific; irrelevant as long as the tracker never refreshes.
- The `opencode`/`opencode-go` duplication means "accounts" must be deduped by key.
- `active` is NULL (not 0) on some older rows (copilot, xai); treat NULL as inactive when there is another row, but there is only one row for those providers anyway.
- Not every provider's usage payload has the same windows. Anthropic: 5h + 7d (+ per-model). OpenAI: plan-dependent (`limit_window_seconds`). Zen: rolling + weekly + monthly. xAI: weekly pool. Copilot (org-pooled): month-to-date consumption only, no pool size.
- xAI's billing payload is proto3-JSON: zero-valued fields (notably `creditUsagePercent`) are omitted, so absence means 0.

## Spike script

The probe used for the live results (Bun). It reads the DB read-only, skips expired tokens, and prints each response. Lived at `/private/var/folders/.../T/opencode/usage-spike/spike.ts` during the spike.

```ts
import { Database } from "bun:sqlite"
import { homedir } from "node:os"

const db = new Database(`${homedir()}/.local/share/opencode/opencode.db`, { readonly: true })

type Row = { id: string; integration_id: string; label: string; active: number | null; value: string }
type OAuth = { type: "oauth"; methodID: string; access: string; refresh: string; expires: number; metadata?: Record<string, unknown> }
type Key = { type: "key"; key: string; metadata?: Record<string, unknown> }

const rows = db
  .query<Row, []>(`select id, integration_id, label, active, value from credential where integration_id not like 'mcp_%' order by integration_id, label`)
  .all()

type Probe = { url: string; headers: Record<string, string> }

function probe(integration: string, value: OAuth | Key): Probe | string {
  switch (integration) {
    case "anthropic":
      if (value.type !== "oauth") return "expected oauth"
      return {
        url: "https://api.anthropic.com/api/oauth/usage",
        headers: { Authorization: `Bearer ${value.access}`, Accept: "application/json", "anthropic-beta": "oauth-2025-04-20", "User-Agent": "claude-code/2.1.69" },
      }
    case "openai": {
      if (value.type !== "oauth") return "expected oauth"
      const accountID = value.metadata?.accountID
      return {
        url: "https://chatgpt.com/backend-api/wham/usage",
        headers: { Authorization: `Bearer ${value.access}`, Accept: "application/json", ...(typeof accountID === "string" ? { "ChatGPT-Account-Id": accountID } : {}) },
      }
    }
    case "github-copilot":
      if (value.type !== "oauth") return "expected oauth"
      return {
        url: "https://api.github.com/copilot_internal/user",
        headers: {
          Authorization: `token ${value.access}`,
          Accept: "application/json",
          "Editor-Version": "vscode/1.96.2",
          "Editor-Plugin-Version": "copilot-chat/0.26.7",
          "User-Agent": "GitHubCopilotChat/0.26.7",
          "X-Github-Api-Version": "2025-04-01",
        },
      }
    case "xai":
      if (value.type !== "oauth") return "expected oauth"
      return {
        url: "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
        headers: { Authorization: `Bearer ${value.access}`, "X-XAI-Token-Auth": "xai-grok-cli", Accept: "application/json" },
      }
    case "opencode-go":
    case "opencode":
      if (value.type !== "key") return "expected key"
      return { url: "https://opencode.ai/zen/go/v1/usage", headers: { Authorization: `Bearer ${value.key}`, Accept: "application/json" } }
    default:
      return `no probe for ${integration}`
  }
}

const now = Date.now()
for (const row of rows) {
  const value = JSON.parse(row.value) as OAuth | Key
  const tag = `${row.integration_id} / ${row.label}${row.active ? " (active)" : ""}`
  if (value.type === "oauth" && value.expires > 0 && value.expires < now) {
    console.log(`\n== ${tag}\n   SKIP: access token expired ${new Date(value.expires).toISOString()}`)
    continue
  }
  const p = probe(row.integration_id, value)
  if (typeof p === "string") {
    console.log(`\n== ${tag}\n   SKIP: ${p}`)
    continue
  }
  const res = await fetch(p.url, { headers: p.headers })
  const text = await res.text()
  let body: unknown = text
  try {
    body = JSON.parse(text)
  } catch {}
  console.log(`\n== ${tag}\n   GET ${p.url} -> ${res.status}`)
  console.log(JSON.stringify(body, null, 2))
}
```

## Reference material

- OpenCode 2 source, branch `beta`: `~/.btca/agent/sandbox/opencode-beta` (`git fetch && git checkout origin/beta` to update). Key files: `packages/core/src/credential.ts`, `packages/core/src/credential/sql.ts`, `packages/schema/src/credential.ts`, `packages/core/src/integration.ts` (`connection.resolve`), `packages/core/src/plugin/provider/{openai,github-copilot,xai,opencode}.ts` (each provider's OAuth method and refresh).
- OpenUsage source: `~/.btca/agent/sandbox/openusage`. Providers under `Sources/OpenUsage/Providers/<Name>/`; the `*UsageClient.swift` files hold the endpoints and headers, the `*UsageMapper.swift` files show how each payload is turned into progress bars.
- Max's Anthropic OAuth plugin: `~/Projects_personal/opencode-claude-auth` (method id `claude-subscription`, token endpoint `https://platform.claude.com/v1/oauth/token`).
- `token-refresh` plugin: `~/my-opencode-setup/plugins/token-refresh/README.md`.
- OpenUsage's local API on `127.0.0.1:6736` (`GET /v1/usage`) is what the existing `openusage` skill reads; a compatible shape would let that skill keep working against the new tracker.
