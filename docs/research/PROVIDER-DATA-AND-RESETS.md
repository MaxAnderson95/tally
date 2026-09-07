# Provider display data and OpenAI banked resets

Research for "Inventory provider display data and OpenAI banked-reset semantics", inspected 2026-09-06. This report inventories data, not a UI or implementation design. All Tally code will be written from scratch.

https://github.com/MaxAnderson95/tally/issues/4

## Findings

- All four providers have account-wide quota readings using the credentials recorded by OpenCode. The earlier Tally spike verified those reads; this research made no provider requests, read no credentials, and consumed no reset. [T1]
- OpenUsage displays more than quotas: local token/cost totals, daily trends, model breakdowns, pacing projections, reset-credit expiry details, and aggregate spend. Most historical readings come from local CLI/database records, not subscription usage endpoints. They are not necessarily attributable to an individual Account. [U5-U10]
- OpenAI banked-reset availability and eligibility are distinct. The spike returned `available_count: 3` with `applicable_available_count: 0`. Neither inspected OpenUsage nor the inspected Codex CLI models the latter field. Its exact semantics and eligibility rules remain unverified. [T1, U2, C2]
- The redemption protocol is implemented in first-party Codex source: POST a client UUID and explicit credit ID using the selected workspace's account header. There is no window selector. The provider decides which windows the reset affects. First-party UI describes monthly or combined weekly/5-hour scope; it is not proof of scope for every current plan. [C1-C4]
- Useful readings can survive restarts with a last-good account-stamped snapshot and its timestamps. Reference pacing needs one snapshot and a clock, not a sampled history database. Detailed local spend parity is a separate requirement because the reference log readers do not establish current OpenCode 2 per-account attribution. [U7-U10, U12]

## Evidence and revisions

All source citations below use the revisions in this table. No shared clone was fetched, checked out, or modified. The Codex clone was already present and inspected read-only as an additional first-party protocol source.

| Reference | Revision / evidence boundary |
|---|---|
| OpenUsage (`robinebers/openusage`) | `70dea9a8fa21ed205aa9ad625b416a1e7792d5a1` |
| OpenCode beta (`anomalyco/opencode`) | `b2cecc6350d377c382e1ec32ee66ec63ad68f715` |
| Codex (`openai/codex`) | `a09a7c41d8abbaec6543664bff04a81058192958`; existing checkout, not asserted to be latest upstream |
| `openusage-web` | HEAD `58ff486a3375ec0599d9c5d60e82be575ed0cc20` plus current uncommitted `main.go`, `static/index.html`, `README.md`, and untracked `main_test.go`. Source findings refer to the working tree, not just HEAD. No runtime/browser check performed. |
| Tally spike | `docs/RESEARCH.md`, prior session `ses_f88b35664ffejzbO6BvsXp7Ttz`, records live GET observations on 2026-09-06. This report did not repeat them. |
| OpenUsage redemption spike | `docs/research/codex-reset-credit-claim.md`, claims one live redemption on 2026-07-12 on Pro. Its raw log is explicitly outside that repository. Treat numerical before/after results as recorded third-party evidence, not independently reproduced facts. |

## Display field inventory

Provenance: **direct** means a provider response or local recorded measurement; **derived** means formatting, arithmetic, pricing, or aggregation; **persisted** describes reference retention, not upstream authority. All successful OpenUsage snapshot lines can be persisted in its snapshot cache. Missing data and measured zero are different states. “Web” below means the current `openusage-web` working tree consuming OpenUsage's legacy `/v1/usage` serialization. [U10-U11, W1]

| Displayed data | Anthropic | OpenAI | OpenCode Go | xAI/Grok | Provenance and web support |
|---|---|---|---|---|---|
| Provider/account card name | Claude, including organization cards | Codex | OpenCode | Grok | Reference card name comes from its own provider/account assembly. Web renders `displayName`. Tally Account name/visibility must instead come from OpenCode. [U13, W1, O1, T1] |
| Plan | Subscription type plus tier multiplier, e.g. Max 20x | `plan_type`, formatted; `prolite` → Pro 5x, `pro` → Pro 20x, `self_serve_business_prolite` → Business Premium | Literal Go after successful Go-meter fetch | Optional settings `subscription_tier_display` | Anthropic source is reference auth metadata, not usage JSON. OpenAI/Grok source is direct response metadata with display formatting; Go label is inferred from successful entitlement. Web displays plan when present. [U1-U4] |
| Main quota used %, remaining %, bar | `five_hour.utilization`, `seven_day.utilization` | `rate_limit.primary_window` and `secondary_window`, `used_percent` | `usage.rolling/weekly/monthly.percent` | `config.creditUsagePercent`, weekly period only | Direct used values; remaining is derived. Web clamps remaining to 0–100 and rounds to whole percent. OpenUsage can toggle used/remaining. [U1-U4, U12, W1] |
| Window duration / cadence | 5h session, 7d weekly | `limit_window_seconds`; primary is not necessarily shortest | Reference assumes 5h session, 7d weekly, fixed month constant for pacing | Actual `currentPeriod.end - start` | OpenAI duration is direct and plan-dependent; Anthropic/Go periods are reference assumptions/constants. Preserve upstream window identity and duration rather than encoding “primary = 5h.” [U1-U4, T1] |
| Reset instant / countdown | `resets_at` per window | `reset_at` epoch seconds, or `now + reset_after_seconds` fallback | ISO `resetsAt` | `currentPeriod.end` | Reset instant direct or anchored relative value; countdown is clock-derived. OpenUsage supports relative/absolute display plus opposite-format tooltip. Web shows countdown, switching to date for ≥7d and `resetting…` after expiry. Elapsed time is not evidence a quota actually reset. [U1-U4, U12, W1] |
| Supplementary quota meters | Sonnet from `seven_day_sonnet`; Fable from `limits[]` matching scoped weekly model display name | Spark / Spark Weekly from first `additional_rate_limits[]` entry whose name or metered feature contains `spark` | Monthly in addition to Session/Weekly | No second subscription quota meter in mapper | Direct percentages, derived labels. Web renders whatever progress rows mapper emits. Reference is selective: it does not render arbitrary Anthropic scopes, Opus legacy bucket, or OpenAI non-Spark named limits. Spike's `gpt-reserve` is consequently omitted. [U1-U2, T1] |
| Extra-usage spend / cap | Enabled `extra_usage`: `used_credits / 100`; bounded dollars when positive monthly cap, otherwise raw dollars only if spend >0 | No analogous row | No remote spend/balance row | PAYG cap badge from `onDemandCap.val`, or Disabled at 0/absent | Anthropic cents conversion is reference behavior; current spike also has structured money with currency/exponent that the mapper ignores. Web bounded dollars show remaining dollars / limit, even for a row named “spent.” Web badge text mismatch noted below. [U1, U4, T1, W1] |
| Purchased/flex credits | None | Credits raw balance, floored and clamped ≥0, plus dollars computed at $0.04 per credit | None | None | Balance is direct; flooring and $ conversion are reference-derived, not a quoted cash balance from usage API. Fallback `has_credits == false` → 0, then header balance. Web renders combined text. Unlimited/overage flags are not displayed by mapper. [U2, U11] |
| Banked reset count | None | `available_count` from dedicated list, falling back to usage embedded summary | None | None | Direct count, floored for reference display. Zero produces a real “0 available” row; malformed/missing count omits row. Web renders count text. [U2, U11] |
| Banked reset expiry timeline / urgency | None | Available credit expiry instants, sorted; numbered rows, exact dates, countdowns; count-only unknown-expiry state | None | None | Expiry direct; order/countdown/urgency derived. Native UI uses expiry thresholds of 48h and 7d. API exposes only soonest expiry on text row; web text renderer ignores that field. No web redemption control. [U2, U14, U11, W1] |
| Today / Yesterday / Last 30 Days tokens and dollars | Claude logs plus optional pi logs | Codex rollouts plus pi plus OpenCode Codex scan | OpenCode hosted Go + Zen message records | Grok completed-turn logs | Tokens are locally recorded counts. Anthropic/OpenAI costs are pricing-derived estimates; Grok prefers recorded costs, falls back to pricing, and labels aggregate estimate; hosted OpenCode sums recorded cost and labels it measured. These are local activity/API-equivalent amounts, not subscription invoices or provider-wide spend. Web receives combined text. [U5-U9] |
| Daily Usage Trend | Yes if local usage exists | Same | Same | Same | Derived calendar-day token totals, idle days zero-filled; default today plus previous 30 days, 31 points despite “Last 30 Days” label. Web renders bars, point date/value tooltip and first/middle/last labels. It does not show chart source note. [U5, W1] |
| Spend detail by model | Yes where scanner attributes models | Same, plus fallback-pricing model warnings | Same | Includes unattributed usage folded into Other | Derived model token/cost totals, shares, model variants, Other grouping, source note, unpriced-model warnings. Not exported in legacy web API. [U5, U11] |
| Cross-provider Total Spend | Contributes | Contributes | Contributes | Contributes | Native aggregate has Today/Yesterday/30 Days; Cost, Tokens, Cost/MTok; totals and ranked provider contributions, estimate marker. Weighted total cost/MTok uses total dollars / total tokens. Derived from spend rows; not an independent provider reading, not rendered by web. Limit contributors to Tally's four supported providers. [U15, W1] |
| Pace / spare / runs out / projection at reset | Bounded quota windows | Same, including mapped supplementary windows | Same, with reference period assumptions | Weekly pool | Derived from one reading plus reset time, duration and clock. Native displays pace classification, even-pace tick, projected % at reset, spare %, possible run-out ETA. Web does not calculate pacing. [U12, W1] |
| “Not started” session state | Zero used and missing reset date | Not declared on Codex session descriptor | Zero used and reset still future | Not declared on weekly pool | Reference inference from snapshot fields, not activity history. “Not started” should not replace unknown data. [U1, U3, U12] |
| Freshness, errors, no-data | All | All | All | All | Snapshot fetch time is locally recorded; age and next-update countdown are derived. Native stale-while-revalidate keeps last-good data and exposes errors/warnings; web shows card Updated age and transport banner, and retains old cards in browser memory on fetch failure. [U10-U12, W1-W2] |

### Data present upstream but omitted by reference display

The spike includes OpenAI `user_id`, `account_id`, `email`, `allowed`, `limit_reached`, `normal_model_slug`, `credits.unlimited`, `overage_limit_reached`, and `applicable_available_count`. OpenUsage's mapper does not turn those into display rows. They still matter for Account targeting, quota applicability and truthful status. Anthropic's structured `limits` and `spend`, dollar limit fields and lock reasons exceed what the selective mapper displays. Grok exposes `onDemandUsed`, `prepaidBalance`, billing-period fields and billing configuration, but the current mapper only displays weekly utilization and PAYG cap. Go `status` is likewise not mapped into a displayed row. Data parity should distinguish these available fields from actual reference display; displaying them would be a deliberate product choice. [T1, U1-U4]

For the spike accounts: Anthropic's positive-limit extra-spend bar was unavailable (`monthly_limit: null`, zero spend), Sonnet/Opus buckets were null, while structured Fable had data. OpenAI Personal had 5h + 7d; Work had only a 7d primary at 100% used. Grok settings returned no plan name, and its weekly zero percent was omitted by proto3 JSON serialization. Those are plan/schema states, not a reason to fabricate a universal set of bars. [T1]

### Web reference gaps are source-observed

`LocalUsageAPI` exports `.values` as legacy `text`, so current web still displays spend, credit dollars/count and banked-reset count. It intentionally drops model breakdowns, unknown-model details and all but the soonest reset expiry. `renderText` ignores that remaining expiry. The serializer exports badge content as `text`, but `renderBadge` reads `value`: for the inspected pair, a Grok PAYG badge renders its label without Disabled/cap content. This is a source-level compatibility mismatch, not a browser-verified result. Do not reproduce the omission as a parity requirement. [U11, W1]

The web backend proxies `/v1/usage`; it does not own history or cache persistence. The browser's `state.providers` survives an HTTP failure only within the current page. Reloading loses it and re-reads the backend. Its force-refresh action is not a banked reset action. [W1-W2]

## Direct, derived, persisted and in-memory readings

| Reading/state | Reference source and retention | Restart consequence / decision input |
|---|---|---|
| Latest quota, plan, balance, banked-reset count/expiries | Successful `ProviderSnapshot` serialized in UserDefaults `openusage.providerSnapshots.v9`; no error snapshot writes | Last known values survive app restart. Launch loads expired values too, but forces a new refresh; stored data is not assumed fresh just because it exists. [U10] |
| Normalized local daily history and model data | Snapshot includes `usageHistory`; scanner reads existing files/SQLite, not accumulated quota polls | Can survive restart from snapshot and be reconstructed while source records remain. Source absence or unaccounted days must not be labeled confirmed zero spend. [U5-U10] |
| Multi-machine history union | Optional iCloud history documents aggregated into rendered snapshots; local snapshots alone are cached/exported to avoid echoing peer contributions | This is a larger reference feature, not required to preserve useful single-machine readings. No need to adopt sync or full archival history for the stated best-effort goal. [U10] |
| Pace, elapsed fraction, spare %, ETA | `elapsed = now - (resetAt - duration)`; projection `used / elapsed * duration`; valid only after `max(60 seconds, 1% of duration)`, with positive usage and future reset | Recompute after restart from cached input fields. No burn-rate sample series is involved. Healthy if projected usage ≤90% allowance, close if ≤100%, behind otherwise. Assumes even usage since inferred window start; not a recent-activity slope. [U12] |
| Reset countdown and expiry urgency | Clock arithmetic against stored timestamps | Recompute; never persist a countdown string as authoritative. An overdue timestamp needs a refresh, not a synthetic zero-usage reading. [U12, U14, W1] |
| Last refresh error, in-flight flags, refresh backoff | Store dictionaries/sets in memory; errors can coexist with last-good snapshot | Reference does not persist these as provider snapshots. Keep freshness tied to successful observation, not failed fetch time. [U10] |
| Anthropic provider-specific last-good usage and rate-limit cooldown | `ClaudeProvider.lastGoodUsage`, cached credential fingerprint and cooldown are process memory, cleared on identity change | Distinct from persisted outer snapshot cache. A restart does not restore provider-internal retry state just because it restores bars. [U1, U10] |
| Claim idempotency and matched credit identity | `RateLimitResetsDetail` has popover `@State` UUIDs keyed by expiry; service has process-lived `matchedCreditIDs` keyed by UUID | Current OpenUsage does not provide durable claim retry continuity. Closing/reopening or restarting can lose the operation UUID; expiry is also not a sound multi-account identifier. [U14, U16] |
| UI preferences | Meter style, reset display mode and always-show-pacing persisted in UserDefaults | Preferences survive independently of measured data; they are not usage history. [U10] |

### Local history attribution is the main parity gap

The hosted OpenCode scanner aggregates `opencode` and `opencode-go` into one local provider history, with no credential/account filter. The Codex scanner gates an `openai` provider history on the current local legacy auth being OAuth and deduplicates message rows; that does not prove which Account produced an older message or whether it used OAuth at that time. It also reads the reference's older OpenCode message JSON layout, not a demonstrated OpenCode 2 account-attributed schema. Claude/Grok reference historical sources are their CLI logs, whereas Max's usage here is OpenCode. [U6-U9]

Therefore source parity does not establish that per-account Today/Yesterday/model totals are available for all four Tally Accounts. Do not copy one provider-wide local total onto every Account, silently sum aliases twice, or present API-equivalent cost as subscription consumption. A later schema investigation can establish which OpenCode 2 usage records have stable credential attribution. If they do not, keep these readings explicitly provider/machine-scoped or mark them unavailable. This report did not query any user's message database. [U7-U9, O1]

## Account identity and visibility

Tally's glossary makes OpenCode the source of truth for Account name and visibility. Its credential schema carries ID, integration association, label, active flag and value; OAuth values have provider method and optional metadata. The spike's `opencode` and `opencode-go` rows were duplicate keys, two distinct keys across four rows. That observed aliasing is the deduplication evidence; matching labels alone is not. Avoid exposing a raw key as a public identity. [O1, T1]

OpenAI `metadata.accountID` is the workspace selector. Send it with the credential whose Account the user chose for usage, reset-list and consume requests. Same access token with different workspace/account ID is not interchangeable. Conversely, email or display label alone is insufficient identity. A renamed Account should retain its history association; a credential replaced with a different upstream account must not inherit the previous account's cached quota just because its label matches. [O1-O2, U16, T1]

The `active` flag selects OpenCode's current connection, not whether another configured Account exists. The spike had inactive Accounts that still returned usage after their credentials were refreshed by OpenCode's plugin. There is no independent `visible` field in the inspected credential table. Exact visibility policy for removed integrations, disabled providers and duplicate aliases remains a Tally/OpenCode integration decision; this research does not equate “inactive” with hidden. Conflicting alias labels or active markers across `opencode`/`opencode-go` need an explicit name/active presentation rule. [O1, T1]

Reference identity handling differs: OpenUsage derives Claude/Codex identities from CLI/default homes and Claude desktop organizations. Its cache has producing-account stamps for those families; Go and Grok do not gain equivalent stamps there. That machinery is evidence that cross-account cache leakage matters, not Tally's source of Account names. [U10, U13]

## Banked-reset protocol and semantics

### Read model

Usage GET returns an embedded count summary. Dedicated GET `https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` returns `available_count` and a `credits` list. First-party Codex decodes `id`, `reset_type`, `status`, `granted_at`, nullable `expires_at`, optional `title` and `description`. Its picker filters explicit `available`, sorts earliest expiry first with nonexpiring credits last, and uses server title when nonblank. The OpenUsage recorded response additionally has redemption timestamps and profile presentation fields; these are not required by the inspected first-party decoder. [C1-C3, U17]

OpenUsage instead reduces list details to count plus expiry dates, tolerates absent status as available, and loses ID/type/title/description/nonexpiring-credit detail in its displayed snapshot. It falls back to embedded count when detail fetch is unavailable or lacks a numeric count. An empty expiry array with positive count is shown as “Expiry times unavailable,” which cannot distinguish a genuinely nonexpiring credit from a failed detail fetch. Expiry timestamps are not unique credit identifiers, even though its view assumes uniqueness. [U2, U14, U16]

Eligibility is unresolved beyond the provider's eventual verdict. `available_count > 0` means banked availability, not proven applicability now. The prior spike's `applicable_available_count: 0` demonstrates a distinct field, but current inspected Codex types expose only `available_count`, and OpenUsage's UI does not gate on applicable count. No source inspected defines the usage threshold, plan rules, or which kinds of current windows a credit can reset. Preserve count, applicable count when supplied, credit status/type and nullable expiry separately; do not convert missing applicability into false. [T1, C2, U2, U14]

### Exact reference request

This is the OpenUsage wire request corroborated by first-party Codex endpoint/body construction. Placeholders below are descriptions, not retrieved credentials. OpenUsage uses a 15-second consume timeout and 10-second list timeout. Its extra beta/originator headers are reference behavior; their necessity was not tested here. [U18, C1]

```http
POST https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume
Authorization: Bearer <selected Account access token>
ChatGPT-Account-Id: <that Account metadata.accountID>
Accept: application/json
Content-Type: application/json
User-Agent: OpenUsage
OpenAI-Beta: codex-1
originator: Codex Desktop

{"redeem_request_id":"<one UUID for this operation>","credit_id":"<selected credit ID>"}
```

The dedicated list uses GET on the URL without `/consume`, with the same reference headers except Content-Type. First-party Codex supports a body without `credit_id` so the server chooses; its picker has that fallback when no detailed options exist. Tally can keep explicit credit selection without adopting that fallback. Neither body has `window_id`, duration, quota percentage or reset scope. Account header and credit ID target the Account and grant, while server credit semantics determine affected windows. [C1, C3]

### Responses and error handling

First-party response type is `{ code, windows_reset }`, with missing `windows_reset` defaulting to zero. OpenUsage's recorded success also returned a richer `credit` object. Inspect the body code, not just HTTP success. [C2, U17]

| Result | Source-established client treatment | Evidence boundary |
|---|---|---|
| `reset` | Success; refresh usage and credit list; `windows_reset` describes count | OpenUsage recorded a 200 with 2 windows reset and subsequent 5h/weekly readings at zero on one Pro account. Not independently repeated. [C2, C4, U17] |
| `already_redeemed` | Treat as successful replay; refresh | First-party CLI and OpenUsage both do so. Server idempotency retention duration and scope are not established by client code. [C4, U16] |
| `nothing_to_reset` | Informational “usage does not need a reset”; do not claim a reset occurred | OpenUsage report says no credit spent; UI disables further claims for that open popover. Exact backend eligibility predicate unverified. [C4, U14, U17] |
| `no_credit` | Target unavailable; refresh list when explicit ID was used | Could reflect expiry, another client consuming it, or no eligible target. Do not infer the current request succeeded. [C4, U16] |
| HTTP 401/403 | Reference service tries another credential candidate | Unsafe pattern to copy across Tally Accounts: reference fallback is not bound to a selected Tally Account. Tally must retain the selected workspace and credential association, including retries. [U16] |
| Other HTTP failure, network error, malformed or unknown response code | Reference displays generic failure; user may retry | A lost response can follow a successful server mutation. Generic “failed” is not evidence the credit was unspent. [U16, C4] |

The reference research says the four logical outcomes arrive as HTTP 200; first-party client types corroborate the codes, but no server implementation or exhaustive response matrix was verified. Preserve unknown codes and transport failures as unresolved outcomes rather than mapping them to “no credit.” [C2, U17]

### Retry and ambiguous-result boundary

Codex mints one UUID for each picker option and captures the same UUID/credit pair in its retry action. OpenUsage mints on first confirmation, then saves the matched credit ID for that UUID in memory. This lets a retry POST the same ID even if the credit disappeared from a new list after a lost success response. Merely re-fetching and finding the credit missing cannot distinguish “this operation succeeded” from expiry or another client consuming it. [C4, U14, U16]

Decision input for Tally: if redemption is implemented and must survive restart, retain a small pending-operation record containing selected Account/workspace identity, explicit credit ID and UUID before sending the POST. A retry must reuse all three, never mint a fresh UUID for an ambiguous attempt or fall through to another Account. A persisted pending operation is operation recovery, not a full history suite. This is a recommendation derived from the reference failure path, not a proven backend guarantee. Server replay retention, duplicate in-flight behavior, and recovery after a long delay remain unknown. [C4, U16]

### UI evidence and remaining live questions

OpenUsage exposes Use on an expiring-credit timeline row, expands inline confirmation, blocks other rows during confirmation/in-flight work, pins the popover, then displays outcome. On success or `nothing_to_reset` it disables further Use buttons for that popover only. It does not initially disable based on zero meter usage or applicable count; the current code's `nothingToReset` state starts false. Count-only/unknown-expiry entries cannot be selected by that UI. [U14]

First-party Codex describes “Full reset (Monthly)” for observed monthly windows or Free/Go plans and “Full reset (Weekly + 5h)” for corresponding durations; otherwise “Full reset.” Its picker prefers the server's title. Those labels are client expectations. Do not assert both 5h and weekly exist for Tally's Work Account, which the spike observed as weekly-only, or assert model-specific windows reset. OpenUsage's own Pro spike calls model-specific reset evidence only suggestive because those windows were already zero. [C3, T1, U17]

Questions requiring a later user decision or approved live redemption, not resolved here:

- What exactly makes a banked reset applicable, and is `applicable_available_count` authoritative for every plan/reset type?
- Which windows reset for current Plus, weekly-only Business Premium and non-Spark supplementary limits? Does `windows_reset` enumerate only base windows or supplementary ones too?
- Does the server preserve UUID replay semantics across process restarts, for how long, and with what Account/credit scoping? How does it answer overlapping identical requests or an operation still in `redeeming` state?
- Are `nothing_to_reset` and `no_credit` always non-consuming across all plans and current backend behavior? Client intent and prior notes support that interpretation; this research did not verify it by mutation.

Source-only work can implement/display count and details and describe the supported request protocol. It cannot honestly certify current multi-plan redemption effects or all failure/replay cases. A later end-to-end check would need explicit approval to consume a chosen credit on a chosen Account and compare before/after usage and detail responses.

## Citation index

Paths and line ranges are from the revisions listed above; local web citations refer to the uncommitted working tree. Source links use immutable revisions.

- **T1:** Tally `docs/RESEARCH.md:21-75,83-139,178-246`, prior live spike and identity/refresh constraints.
- **O1:** OpenCode `packages/core/src/credential/sql.ts:1-15`; `packages/schema/src/credential.ts:31-51`. Credential labels/active state and value schema.
- **O2:** OpenCode `packages/core/src/plugin/provider/openai.ts:263,332-368`. Account metadata and outgoing account selection.

https://github.com/anomalyco/opencode/tree/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src

- **U1:** `Sources/OpenUsage/Providers/Claude/ClaudeUsageMapper.swift:15-36,94-173`; `ClaudeProvider.swift:27-33,55-71,291-313,425-445`.
- **U2:** `Sources/OpenUsage/Providers/Codex/CodexUsageMapper.swift:15-65,117-225,228-332`.
- **U3:** `Sources/OpenUsage/Providers/OpenCode/OpenCodeUsageMapper.swift:14-22,36-50`; `OpenCodeProvider.swift:82-99,136-198`; `Support/MetricPeriod.swift:6-10` (month = 30 days).
- **U4:** `Sources/OpenUsage/Providers/Grok/GrokUsageMapper.swift:12-49`; `GrokCreditsConfigDecoder.swift:5-17,41-83`.
- **U5:** `Sources/OpenUsage/Providers/SpendTileMapper.swift:20-128,166-195,292-379`.
- **U6:** `Sources/OpenUsage/Providers/Claude/ClaudeProvider.swift:291-313`; `Grok/GrokProvider.swift:87-123`.
- **U7:** `Sources/OpenUsage/Providers/Codex/CodexProvider.swift:136-215`.
- **U8:** `Sources/OpenUsage/Providers/OpenCode/OpenCodeUsageScanner.swift:3-18,45-105,141-143`.
- **U9:** `Sources/OpenUsage/Providers/OpenCode/OpenCodeCodexUsageScanner.swift:3-6,28-100,111-120`.
- **U10:** `Sources/OpenUsage/Stores/ProviderSnapshotCache.swift:5-38,43-64,82-149,179-190`; `WidgetDataStore.swift:71-121,169-189`.
- **U11:** `Sources/OpenUsage/Services/LocalUsageAPI.swift:100-183`.
- **U12:** `Sources/OpenUsage/Support/Pace.swift:20-63`; `Models/WidgetData.swift:144-190,473-561,579-632`.
- **U13:** `Sources/OpenUsage/Services/ProviderAccountAssembly.swift:13-20,86-105,150-187,233-254`.
- **U14:** `Sources/OpenUsage/Views/RateLimitResetsDetail.swift:18-60,117-150,265-320,362-414,435-475`.
- **U15:** `Sources/OpenUsage/Support/TotalSpendAggregator.swift:3-8,27-78,101-155`.
- **U16:** `Sources/OpenUsage/Providers/Codex/CodexResetClaimService.swift:27-37,82-125,129-235`.
- **U17:** `docs/research/codex-reset-credit-claim.md:3-11,34-107,109-124`. Recorded prior live test; raw evidence unavailable in repo.
- **U18:** `Sources/OpenUsage/Providers/Codex/CodexUsageClient.swift:79-154`.

https://github.com/robinebers/openusage/tree/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/docs/research/codex-reset-credit-claim.md

- **C1:** `codex-rs/backend-client/src/client/rate_limit_resets.rs:14-19,37-108`.
- **C2:** `codex-rs/backend-client/src/types.rs:22-42,74-88`.
- **C3:** `codex-rs/tui/src/chatwidget/reset_credits.rs:13-129`.
- **C4:** `codex-rs/tui/src/chatwidget/usage.rs:170-201,242-324`.

https://github.com/openai/codex/blob/a09a7c41d8abbaec6543664bff04a81058192958/codex-rs/backend-client/src/client/rate_limit_resets.rs

https://github.com/openai/codex/blob/a09a7c41d8abbaec6543664bff04a81058192958/codex-rs/backend-client/src/types.rs

https://github.com/openai/codex/blob/a09a7c41d8abbaec6543664bff04a81058192958/codex-rs/tui/src/chatwidget/reset_credits.rs

https://github.com/openai/codex/blob/a09a7c41d8abbaec6543664bff04a81058192958/codex-rs/tui/src/chatwidget/usage.rs

- **W1:** `/Users/max/Projects_personal/openusage-web/static/index.html:225-229,255-279,292-423`, current working tree.
- **W2:** `/Users/max/Projects_personal/openusage-web/main.go:37-99`, current working tree.

## Checks performed

Read the provider data research ticket through `gh api`; read Tally instructions, glossary and prior spike; inspected the cited local source and revisions. No tests, provider calls, credential refreshes, redemption, or runtime UI checks ran. Only this report was written. Parent session owns tracker resolution and publication.
