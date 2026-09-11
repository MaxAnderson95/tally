# Tally v1 specification

Status: accepted by Max on September 7, 2026. This document consolidates the wayfinder decisions and the final ambiguity review. It specifies the application to build; it does not claim an implementation exists.

## 1. Destination and decision sources

Tally is a personal Apple Silicon macOS 26+ app that reads remaining AI subscription usage for multiple Anthropic, OpenAI, OpenCode Go, and xAI/Grok Accounts stored in one local OpenCode V2 database. It has a native menu bar, mobile/desktop web, REST interface, and an OpenCode companion tool. OpenCode owns authentication, token refresh, and Account names. Tally code is written from scratch.

The named resolutions below are the decision provenance. This spec is the consolidated implementation contract. Later explicit decisions supersede earlier ones as listed in section 12. `CONTEXT.md` is the glossary; research files are dated evidence, not competing specifications.

| Decision | Source |
| --- | --- |
| Find the way to an implementation-ready Tally v1 spec | https://github.com/MaxAnderson95/tally/issues/1 |
| Study app architecture, packaging, and lifecycle in OpenUsage and openusage-web | https://github.com/MaxAnderson95/tally/issues/2 |
| Verify OpenCode credential, model-tool, TUI, and context-injection capabilities | https://github.com/MaxAnderson95/tally/issues/3 |
| Inventory provider display data and OpenAI banked-reset semantics | https://github.com/MaxAnderson95/tally/issues/4 |
| Define Tally's single-app architecture, credential access, and lifecycle | https://github.com/MaxAnderson95/tally/issues/5 |
| Define account readings, data freshness, and best-effort persistence | https://github.com/MaxAnderson95/tally/issues/6 |
| Define menu bar and mobile web usage presentation | https://github.com/MaxAnderson95/tally/issues/7#issuecomment-5572674916 |
| Define REST API and banked-reset redemption across clients | https://github.com/MaxAnderson95/tally/issues/8 |
| Verify OpenCode local activity attribution, Go separation, and history coverage | https://github.com/MaxAnderson95/tally/issues/10 |
| Verify API-equivalent activity pricing source and model matching | https://github.com/MaxAnderson95/tally/issues/11 |
| Validate Tally's menu bar and mobile presentation with a visual prototype | https://github.com/MaxAnderson95/tally/issues/12#issuecomment-5573421403 |
| Check remaining ambiguities and consolidate the implementation-ready v1 spec | https://github.com/MaxAnderson95/tally/issues/13 |

Out of scope: OpenCode Zen and its prepaid activity, other providers including Copilot, public hosting, shared users, multiple hosts, independent login/refresh, automatic Account switching or stopping model work, proactive context injection/TUI alerts, a dedicated companion TUI, full OpenUsage settings parity, a quota-history archive, and implementation or shipping during this planning effort.

## 2. Runtime, installation, and compatibility

Decided by **Define Tally's single-app architecture, credential access, and lifecycle** and **Define REST API and banked-reset redemption across clients**. See [ADR 0001](adr/0001-single-app-runtime.md).

- One resident Swift app owns provider collection, scheduling, cached readings, activity derivation, commands, and recovery. Native UI calls the shared Swift module directly. Hummingbird exposes that module to HTTP clients. Clients do not read credentials, contact providers, calculate pricing, or coordinate redemptions.
- Bundle a React/TypeScript/Vite SPA in the app resources. Serve `/` and real assets with Vite base `/`. Build tools and Node are required only on the build machine. `/api` and `/api/*` always dispatch to JSON API handling; unknown API routes and missing assets never return successful SPA HTML. Add restricted history fallback only if actual browser routes require it.
- Bind HTTP to loopback on a saved, explicitly configured stable port. Never silently choose a new port on collision. An independently configured Tailscale proxy owns personal-tailnet HTTPS exposure. Setup documents the chosen port and proxy configuration; Tally does not manage Tailscale.
- Enable launch at login during setup and allow disabling it. Closing the popover leaves all work running. Quit rejects new commands and waits at most 15 seconds for in-flight redemption. Crash recovery is manual. App lifetime, independently of views, owns the HTTP run task and awaits its shutdown.
- A listener failure leaves native collection usable. Show web/API unavailability with retry and port settings. A retry creates a fresh server lifetime. Provider failures remain independent.
- Distribute an unsigned personal app as downloadable releases. Max accepts manual macOS approval. Updates manually replace the app; no in-app updater, Developer ID signing, or notarization is required. Runtime and web assets ship together. A web tab reloads on an app-build change.
- Release the companion separately against API major 1. Additive fields are compatible within v1. An incompatible companion reports an update requirement instead of demanding equal app/companion release numbers.
- Document tested OpenCode and dependency revisions in each implementation release. The research snapshot establishes feasibility, not binary compatibility or selected dependency pins. Validate an actual packaged Apple Silicon build before release.

## 3. Inventory, identity, and setup

Decided by **Define account readings, data freshness, and best-effort persistence**, **Define menu bar and mobile web usage presentation**, and **Check remaining ambiguities and consolidate the implementation-ready v1 spec**.

Read the standard local OpenCode V2 database read-only, with one explicit path override in settings. The recorded default is `~/.local/share/opencode/opencode.db`; implementation must honor the platform's applicable OpenCode data-path discovery and document it. Never migrate or write OpenCode's database. Validate the fields needed for credentials and activity independently; compatible schema additions are accepted. Incompatible reads report an error and retain correctly associated last-good data as stale.

Include supported stored subscription Accounts, active and inactive, independently of project model catalogs. Exclude environment-only connections, MCP connections, unsupported authentication methods, and Zen entries before deduplication. Use OpenCode names verbatim, including casing. A display name is not unique identity.

Deduplicate only proven same-service identities. Different OpenAI workspace IDs remain separate even with a shared token. Different Go keys remain separate absent evidence of common identity. For a proven duplicate, choose the stable first stored entry by creation time then credential ID; active selection does not rename it. Preserve a Tally opaque Account ID through renames and verified same-account refreshes. Clear readings when identity changes or continuity cannot be established. Successful removal deletes that Account's reading cache and pins; an unreadable inventory is not a removal event. Never put a raw credential or workspace ID in a public Account ID.

Namespace inventory identity by the selected database. Switching to a different database clears the displayed old inventory/activity, retains old command records without retargeting them, and initializes the new namespace. Returning to a recognized database restores its preferences and restores its cached readings as stale. A replaced database with unproven continuity is a new namespace, even if its path or row IDs match. Across namespaces, proven same upstream Account identity must not evade an unresolved redemption block; uncertainty about an existing command's target must not silently authorize a new consume.

Initial setup remains pending through failed or empty inventory reads. On the first successful nonempty inventory, pin the whole batch in provider order Anthropic, OpenAI, OpenCode Go, xAI, then OpenCode name, then stable ID. Use deterministic case-insensitive name ordering with original name and ID tie-breakers. Assign identity colors in that same order within each provider. Later discovered Accounts start unpinned. Persist a provider-local assignment sequence, wrapping after six; removing another Account never changes an existing color. Restored recognized identities keep their saved association.

The Mac app manages pin selection and order. Web reflects it and has no pin-setting mutation. All-unpinned and empty inventories retain a plain Tally menu bar glyph. Setup/settings also expose database path, launch at login, listener port, and allowed web origin/Host configuration. Account management and authentication direct the user to OpenCode.

## 4. Readings, collection, and recovery

Decided by **Define account readings, data freshness, and best-effort persistence** and **Define REST API and banked-reset redemption across clients**.

### Observation semantics

Preserve every interpretable quota window with stable provider-derived identity, scope, duration when established, observed used percentage, and reset instant. Do not assume an OpenAI primary window lasts five hours. Duplicate representations of the same provider meter produce one normalized window. Preserve independently observed plans, extra usage, balances, reset summaries, and credit details. Unsupported/absent groups differ from groups never observed and from failed observations.

Each independently collected group has its own data, successful observation time, attempt time, stale flag, refreshing flag, next attempt, and error. A single endpoint may update several groups together; a failing optional request cannot stale an independently successful group. Successful absence replaces the previous value. Failure preserves last-good data and its observation time. Null is not measured zero. Values keep their source units and provenance.

A group is stale after five minutes without success, immediately on failed refresh/credential-access failure, and on restoration from disk. A quota window also becomes stale when its reset instant passes. Keep its last observed percentage and show "Reset time passed; awaiting update". Never infer replenishment or a new reset instant from elapsed time.

### Scheduling

- Poll every included Account every two minutes while awake. Refresh on launch/wake and explicit request. Read inventory on that cadence and before targeted commands so known replacement cannot retarget old data.
- Retry collection failures after 2, 4, 8, then 15 minutes, capped at 15. Honor longer provider Retry-After. Healthy Accounts continue normally. Retain known cooldown deadlines across ordinary restart so relaunch does not bypass them.
- Explicit refresh joins in-flight work, respects cooldowns, and has a 60-second minimum between attempts. Launch/wake does not bypass known cooldowns. Return scheduling state without waiting for all results.
- Expired/rejected credentials block further attempts with that credential until OpenCode supplies changed usable credentials. Tally never refreshes tokens. Expiry alone is not proof the user must reauthenticate.
- Activity scanning is independent: two-minute cadence, launch/wake, and every explicit refresh, even when targeted provider requests are deferred. Use the same five-minute freshness baseline, immediate staleness on failed scans, and a separate scheduling result.

### Persistence and pacing

Keep one last-good reading per group for each current Account, with producing identity and timestamps. Damaged or unwritable reading caches do not stop collection. This is best-effort recovery with no quota sample archive. Persisted countdowns or derived projections are not authoritative. Command recovery in section 8 has stronger durability requirements.

Compute pacing in the shared owner from known duration `D`, future reset `R`, current time `t`, and positive observed usage `U` in percent. Let `E = t - (R - D)`. Require fresh input, `0 < E < D`, and `E >= max(60 seconds, 0.01 * D)`. Projected usage at reset is `U * D / E`; spare allowance is `100 - projected`; the average-rate exhaustion instant is `(R - D) + E * 100 / U`. Report run-out only when it occurs before the reset, otherwise explain that allowance is projected to last through reset. Preserve negative spare and over-100 projections. These are current-window average estimates, not measured recent burn rate. Recompute with the clock; suppress for invalid inputs with a reason.

Go Monthly remains visible with its reset, but has no invented 30-day duration or pacing. A fresh five-hour window with explicitly zero usage and absent reset can say "Not started" only where the provider mapping establishes that meaning. Other missing reset instants say "Reset time unavailable".

## 5. Provider interpretation

Decided by **Inventory provider display data and OpenAI banked-reset semantics**, the reading decision, and the visual prototype. Evidence: [provider inventory](research/PROVIDER-DATA-AND-RESETS.md) and [dated viability spike](RESEARCH.md). The spike's old Zen inclusion and refresh claims are superseded by this spec and [integration corrections](research/OPENCODE-INTEGRATION.md#corrections-and-qualifications-to-docsresearchmd).

| Provider | Collection and interpretation |
| --- | --- |
| Anthropic | OAuth usage endpoint supplies five-hour/weekly windows and structured scoped limits. Normalize equivalent legacy/structured meters once, preserving source identity. Prefer structured money with explicit currency/exponent over legacy credit-unit money where both describe the same observation. Plan comes only from available verified subscription metadata, otherwise unknown. Show account-wide windows and Fable, the only displayed model-specific meter. |
| OpenAI | WHAM usage and dedicated reset-credit details use the selected credential plus its `ChatGPT-Account-Id` workspace. Read actual window durations and plan. Plus/Pro can have five-hour and weekly; Business Premium can be weekly-only. Retain additional interpretable windows in REST but do not display supplementary model-specific subscription rows such as Spark. Preserve purchased credit count and the reference-derived $0.04-per-credit comparison separately from provider money. |
| OpenCode Go | Read the Go usage endpoint using Go inventory entries only. Rolling is the established five-hour window, weekly is seven days; Monthly has a reset but no assumed duration. Successful Go entitlement can supply the Go plan label. Never add Zen balance/activity because its key is shared. |
| xAI/Grok | Billing `format=credits` provides the weekly pool and PAYG fields; optional settings supply a plan only when reported. Use actual weekly period start/end. Under the verified compatible proto3 billing schema, omitted `creditUsagePercent` means zero; a malformed present value is an error. This is a provider-specific decoder rule, not a general null-to-zero rule. Nonweekly periods do not fabricate a weekly meter. |

Native/web display all interpretable account-wide windows plus Anthropic Fable. Other scoped windows remain in REST with `displayInOverview: false`. Fable is a scoped suballowance, not additional weekly capacity; its details explain the accepted up-to-half-of-weekly scope. Do not infer missing meters from plan names or convert Fable percentage into account-wide weekly usage.

Extra usage/PAYG appears in the card body without expansion. Explicitly disabled is "Off". Enabled with no positive reported limit shows used only, including measured zero, and no bar. A positive compatible-currency limit shows remaining first, a remaining bar, and used beneath. Unknown enabled state or amount stays unavailable. Never invent a cap, combine different currencies, or label unknown usage as zero. A derived OpenAI credit dollar value is marked reference-derived in details/REST, not a provider-reported cash balance.

## 6. Native and web presentation

Decided by **Define menu bar and mobile web usage presentation**, **Validate Tally's menu bar and mobile presentation with a visual prototype**, and the consolidation review.

Accepted synthetic prototype:

https://github.com/MaxAnderson95/tally/blob/90125e73d61894d33fd12229a5fdf9c9f8ae4350/docs/prototypes/PROTOTYPE-presentation.html

### Cards and layout

Use Cards on all surfaces. Header: tinted provider logo, verbatim Account name, secondary plan, stale/outcome marks, details chevron. Quotas precede the separate Recorded OpenCode activity section. "Pinned" follows saved pin order. "Other accounts" uses the provider order in section 3 and name sorting within each provider, with provider headings.

The shortest known-duration displayed window leads with a large remaining percentage, window label/countdown on the same line, then its bar. Tied duration rows use stable window-ID order in cards. Longer windows follow with label/percentage, bar, and countdown beneath. Unknown-duration windows follow known durations in stable ID order, labeled "duration unknown". If only unknown-duration windows exist, render those rows without inventing a shortest hero. All bars use the full card content width and 4px height. Remaining percentage display is `clamp(100 - usedPercent, 0, 100)`, rounded to the nearest whole percent; REST retains unrounded observation and derived percentage.

Popover width is 360px; hero type is 30px in the popover and 36px on phone. Validate phone at 320px and 390px. Desktop at 1000 CSS px and wider uses account cards on the left (about 60%, `auto-fill, minmax(280px, 1fr)`) and sticky activity on the right. Below 1000px, activity follows all Accounts in one column; it is not sticky. Use the header "Tally", last update age, and "Refresh" on all surfaces. Do not show hostname/tailnet labels. The global update age is the latest successful refresh observation and does not replace per-group freshness or imply all Accounts are current.

OpenAI credits have a body row such as "12 credits ($0.48)". "N reset credits" is the sole action chip below the card; other data does not become chips. Unknown/reset-count-unavailable states remain distinguishable from zero. An unresolved command warning remains accessible even if the count/details cannot be read.

Expanded details are key-left/value-right in two columns on every surface: observation times/ages and errors by group, extra usage, available/provider-applicable reset counts, one Mac-timezone line, then window scope, used percent, exact reset, and pacing or reason unavailable. Countdowns lead; exact dates use the Mac timezone on both clients. Wrap long values without horizontal overflow.

No reading shows `?`, "Plan unknown" where appropriate, and dashed unavailable windows with errors in details. Stale values keep their last percentages plus a monochrome warning and age. A known percentage with unknown duration remains a known percentage; its dashed bar/label signals timing uncertainty. A missing percentage stays `?`.

Native and each browser follow their own system appearance. No separate theme preference is required. Visible web pages poll cached state every 15 seconds, immediately on foreground return, and accepted pending operations every second. Hidden tabs pause polling. Resuming queries an existing operation ID, never creates another redemption. Transport failures preserve the last browser view with an explicit connection error and stale state; they do not advance observation time.

### Pins and identity palette

Pin candidates are account-wide windows with known duration, excluding Monthly. Model-specific windows including Fable never enter pins. Group candidates by duration; within each group choose lowest remaining percentage, stable window ID on a tie. Unknown percentages count as unknown, not as zero: if any tied candidate lacks a percentage, that duration's line is `?` rather than claiming a known worst case. Select at most the two shortest distinct eligible durations, shortest on top. One eligible duration uses a single line; none or no successful quota reading uses `?`. Monthly-only accounts therefore have `?` pins despite a usable Monthly card row.

Each pin is a tinted 15px provider logo, 3px gap, 4px horizontal padding, and 2px between pins. Two-line type is 9.5px semibold with 1.05 line height; single type is 12px medium. Stale lines keep their percentage and append a monochrome warning triangle; hover names the Account, provider, selected windows, percentages, and staleness. Match the accepted 14-pin/1440px-class reference case beside a clock; do not promise fit alongside arbitrary third-party status items or every notch arrangement.

| Sequence | Light | Dark |
| --- | --- | --- |
| Mono | `#1d1d1f` | `#f5f5f7` |
| Cobalt | `#2456e6` | `#7d9bff` |
| Tangerine | `#d96d0b` | `#ffa24a` |
| Moss | `#1e8a4c` | `#4fd08a` |
| Plum | `#8b3fc9` | `#c58bf2` |
| Rose | `#cf2f5a` | `#ff7e9e` |

Identity color appears only in pin logos and card header logos. Bars/text/chips are neutral. Repeat the palette after six without numeric badges. Account names, logo shapes, order, and hover text provide non-color distinction. Status uses a monochrome warning and text, never identity color.

## 7. Recorded OpenCode activity and pricing

Decided by the local-activity research, pricing research, presentation resolution, and consolidation review. Technical evidence and initial rate tables: [local activity](research/LOCAL-ACTIVITY.md) and [API-equivalent pricing](research/ACTIVITY-PRICING.md).

### Source and ranges

Read retained non-copied V2 assistant projections once, including ordinary migrated assistants and actual child-agent requests. Exclude known copied fork prefixes using the verified lineage/timestamp rule; do not add V1 remnants, event replays, or session totals. Do not use token/model fingerprints as universal request IDs. Normal rescans replace totals rather than adding them. Source deletion can lower a fresh total.

Filter recorded provider IDs `anthropic`, `openai`, `opencode-go`, and `xai`. Exclude `opencode` and other providers before aggregation. "OpenCode Go provider activity" accepts the recorded Go label with historical route/prepaid-fallback qualifications; it does not prove quota billing. Model family does not determine provider. Never attribute this history to current Accounts, even when only one exists. Imported records can originate elsewhere; "this Mac's OpenCode records" describes the database, not proven physical execution origin.

Use assistant creation time and this Mac's current timezone. Today is local midnight through the captured scan cutoff; Yesterday is the previous calendar day; Last 30 days is today plus 29 preceding local days. Boundaries are half-open. Exclude future timestamps. Calendar addition, not multiples of 86,400 seconds, handles DST. A request crossing midnight belongs to its creation day.

Always show a 30-local-day token trend with the selected range highlighted. Totals and provider/model breakdowns follow the selected range; the REST trend is separately identified as the 30-day context. Today is default. Keep timezone, partial-history qualification, and scan freshness visible; information details explain deletions, imports, fork exclusions, missing final usage, and unallocated title/compaction calls. First/last retained timestamps and populated-day counts are observations, not continuous coverage guarantees.

Distinguish a successful empty scan ("No recorded activity"), records lacking usage ("Usage missing"), failed/unreadable source ("Unavailable" or stale last-good), and recorded zero. Preserve five disjoint token components: noncached input, visible output, reasoning, cache read, and cache write. Sum them once. Upstream normalization can hide omitted provider components; recorded zeros are not independently audited provider measurements.

Cache the last successful derived view with source/schema identity, timezone/ranges, timestamps, pricing revision, and coverage. Restore stale. Rebucket after timezone changes; if source is unavailable, keep incompatible cached buckets explicitly stale in their original timezone. Never relabel or merge incompatible buckets. Removing an Account cannot selectively delete unattributed provider history.

### API-equivalent estimate

Use a reviewed release-bundled set of first-party standard synchronous/global rates, plus Go's published reference-token rates. Initial evidence is revision `2026-09-07-r1` from the pricing research. Implementation packages the reviewed tables, source excerpts, retrieval dates, immutable content digest, currency/units, component semantics, and tier operators. Subsequent updates use a reviewed app release. No runtime catalog pricing feed is required.

Match exact provider/model pairs, with only individually evidenced aliases. Do not strip suffixes, infer a price from recorded cost, or substitute model-family rates. Unreviewed models stay visible and unpriced. models.dev is discovery/comparison evidence, not authority. Go's first-party table wins over the documented catalog discrepancy.

Price each request before aggregation. For the verified current records, prompt is input + cache read + cache write; output-rate quantity is visible output + reasoning once. Apply OpenAI's strict `>272000` prompt tier and xAI's specific table's `>=200000` tier for the reviewed models. Do not share a universal threshold operator. Unknown positive components or unreconstructible tier inputs remain unpriced while calculable components retain their subtotal.

Use the documented Anthropic 5-minute/1-hour cache-write bounds and Go DeepSeek off-peak/peak bounds. Do not infer write duration or the server's pricing instant from creation time. Exact scalar, bounded, partial, and unpriced states remain distinct. Any missing usage or excluded unpriced contribution makes the selected activity estimate visibly incomplete. Bounds cover included priced components only, never unknown contributions or actual invoices. Missing-usage token quantities cannot become an unpriced-token zero.

Keep OpenCode-recorded cost separate, with ambiguous zeros labeled "Recorded $0; pricing provenance unknown". Never fill price gaps with recorded cost. The API-equivalent estimate is dated reference-token value, not a subscription charge, historical bill, measured quota consumption, savings, or a bound on actual fees. Exclude unreconstructible non-token fees. Any cost/token ratio uses exactly the same priced component subset.

Recompute retained views when the approved bundle changes. Stamp every view with the revision/date. Preserve old cached revision until successful recomputation; never mix estimates across revisions. Show cross-provider tokens/estimate, the daily trend, and expandable provider/model breakdowns with coverage and reasons for unpriced contributions.

## 8. Banked-reset commands

Decided by **Define REST API and banked-reset redemption across clients**, its confirmation correction, the presentation/prototype resolutions, and the consolidation review.

### User interaction and authority

Native/web open account-scoped credit details from the count (hover or click desktop, tap mobile). Show available count, provider-applicable count if known, per-credit title/status/type/expiry, and "Redeeming consumes one credit; the provider decides which windows reset". A per-credit Use action opens inline confirmation naming the Account and consumption of one credit. Cancel sends nothing. While pending, disable every Use action for that Account and label the chosen action "Redeeming…"; no separate progress panel is needed.

Show concise recognized outcomes without promising a window set. An unacknowledged unknown outcome remains a card-header warning after details close. It opens the explanation and Acknowledge action. Acknowledgement releases the block, keeps the result unknown, and never retries. A confirmed reset with failed collection says "Reset confirmed; usage update unavailable" with stale readings.

Each companion redemption requires a specific explicit user request. Standing permission, low usage, and "keep working" are insufficient. Clarify ambiguous Accounts. Acknowledgement also needs explicit user instruction. Tally trusts the local client and cannot independently verify the model's conversation. No automatic redemption, fallback Account, or active-Account targeting exists.

### Selection, send, and outcomes

Accept a client UUID and optional explicit credit ID for one opaque Account ID. Omitted credit requests automatic selection. Preflight current credit details using that Account's current verified credential/workspace and collection cooldowns. No identifiable available credit, credentials failure, or failed/deferred preflight ends before consume; do not queue a later credit spend after cooldown. Known spent/expired credits are not candidates. Do not gate on applicable count, utilization, or invented eligibility thresholds.

Sort identifiable available candidates by dated expiry first, confirmed nonexpiring second, unknown expiry third, then credit ID. An explicit credit selects only itself. Pin selection before send; never substitute after a consume attempt. Unknown expiry is not nonexpiring. A null expiry in a successfully decoded schema that defines null as nonexpiring is `none`; absent/unreadable expiry is `unknown`.

Before contacting OpenAI, persist accepted operation identity, original account/selection request, target identity association, and request UUID. Persist pinned credit and a may-send marker durably before consume. Store no credentials. Required-storage failure declines consume. The credit-list timeout is 10 seconds; consume timeout is 15 seconds. Send exactly one consume POST with selected workspace header, explicit `credit_id`, and `redeem_request_id`. No transport machinery may resend it.

| State | Meaning |
| --- | --- |
| `pending` | Accepted and preflighting/sending; another operation on the Account is blocked. |
| `confirmed` | Recognized `reset` or `already_redeemed`; retain the code and nullable `windows_reset`. The latter does not claim this invocation reset additional windows. |
| `nothing_to_reset` | Provider says no reset is needed; not a confirmed reset. |
| `no_credit` | No identifiable available credit in preflight, or recognized provider `no_credit`; distinguish via result/error fields. |
| `failed` | Known pre-send failure or definitive non-consuming failure; do not use for an ambiguous send. |
| `unknown` | A consume may have reached the provider but no definitive result was retained. Blocks the Account until explicit acknowledgement. |

Lost response, cancellation, malformed/unknown result, and post-send failures without a definitive non-consuming verdict are unknown. Refresh quotas/credits after outcomes and ambiguous sends through the owner, respecting scheduling. Provider confirmation completes independently of refresh success. Changed quota or disappearance of a credit alone cannot resolve uncertainty.

### Duplicate suppression and shutdown

The same UUID with the same original Account and credit-selection request returns the stored operation without another consume, including automatic selection after it has pinned a credit. A changed original request under that UUID is a conflict. Another UUID for a blocked Account conflicts with the blocking ID; different Accounts proceed independently. A new deliberate redemption needs a new UUID. HTTP retry must reuse the old UUID.

Persist operation/result/acknowledgement records across restart without automatic pruning in v1. If interruption happened before a durable may-send marker, terminate as failed without sending. If send may have occurred without a retained definitive result, restore unknown. Never resume a spend on startup. Storage failure after provider response must retain a conservative recovery block until the result can be persisted; after restart missing durability means unknown. Acknowledgement is effective only once durably recorded.

Account removal/replacement never retargets an old operation or erases uncertainty into a replacement. Browser disconnect does not cancel accepted work. On Quit, reject new commands and wait at most 15 seconds; interrupted work follows the recovery rules. No correctness assumption depends on undocumented provider replay guarantees.

## 9. REST contract

Decided by **Define REST API and banked-reset redemption across clients**, the presentation activity contract, and the consolidation review. The following TypeScript notation defines JSON wire shapes, not a requirement to generate Swift or add a schema framework. Swift Codable and handwritten TypeScript DTOs must agree through representative JSON fixtures.

### Conventions and access

Use `/api/v1`, RFC 3339 UTC instants, local `YYYY-MM-DD` dates for calendar labels, finite JSON numbers for percentages/counts, and decimal strings for money. Fields shown are required unless marked `?` in request types; unavailable values use null, not omitted successful-response fields. Strings that are IDs are opaque to clients. Arrays have deterministic ordering. Additive fields remain compatible; clients ignore unknown fields. Do not expose credentials, raw provider payloads, local database paths, or workspace identifiers.

Trust loopback clients and clients admitted by Max's personal Tailscale policy; no separate login/bearer token. Validate allowed Host values and browser mutation Origin against the configured origin. Mutations are JSON-only and no permissive cross-origin access is exposed. Non-browser local clients may omit Origin. This authorizes trusted clients, not individual model intent.

```ts
type Instant = string
type Decimal = string
type Provider = "anthropic" | "openai" | "opencode-go" | "xai"
type Range = "today" | "yesterday" | "last30days"
type Fault = {
  code: string
  message: string
  retryAt: Instant | null
  blockingOperationId: string | null
}
type Group<T> = {
  data: T | null
  observedAt: Instant | null
  lastAttemptAt: Instant | null
  stale: boolean
  refreshing: boolean
  nextAttemptAt: Instant | null
  error: Fault | null
}
type Money = {
  amount: Decimal
  currency: string
  provenance: "provider" | "reference_conversion"
  source: { amount: Decimal; unit: string; exponent: number | null }
}
type Pacing = {
  projectedUsedPercent: number
  sparePercent: number
  runOutAt: Instant | null
  runOutReason: string | null
}
type QuotaWindow = {
  id: string
  label: string
  scope: "account" | "model" | "other"
  scopeNote: string | null
  modelId: string | null
  cadence: "rolling" | "weekly" | "monthly" | "other"
  durationSeconds: number | null
  durationSource: "provider" | "verified_mapping" | "unknown"
  usedPercent: number | null
  remainingPercent: number | null
  resetAt: Instant | null
  resetState: "scheduled" | "passed" | "not_started" | "unknown"
  stale: boolean
  displayInOverview: boolean
  pacing: Pacing | null
  pacingUnavailableReason: string | null
}
type ExtraUsage = {
  enabled: boolean | null
  used: Money | null
  limit: Money | null
  remaining: Money | null
  remainingPercent: number | null
  periodLabel: string | null
  presentation: "off" | "used_only" | "bounded" | "unavailable"
}
type Balance = {
  unit: string
  quantity: Decimal | null
  money: Money | null
  referenceValue: Money | null
  unlimited: boolean | null
}
type Credit = {
  id: string
  type: string | null
  status: string | null
  available: boolean | null
  title: string | null
  description: string | null
  grantedAt: Instant | null
  expiry: { kind: "at"; at: Instant }
    | { kind: "none" | "unknown"; at: null }
}
type PinLine = {
  windowId: string
  label: string
  remainingPercent: number | null
  stale: boolean
}
type CommandSummary = {
  blockingOperationId: string | null
  state: "pending" | "unknown" | null
  acknowledgementRequired: boolean
}
type Account = {
  id: string
  provider: Provider
  service: "claude-subscription" | "chatgpt-subscription" | "opencode-go" | "grok-subscription"
  name: string
  pinned: boolean
  pinOrder: number | null
  identityColorIndex: number
  pin: { lines: PinLine[]; warning: boolean }
  groups: {
    plan: Group<{ name: string }>
    quotas: Group<{ windows: QuotaWindow[] }>
    extraUsage: Group<ExtraUsage>
    balances: Group<{ items: Balance[] }>
    resetSummary: Group<{
      availableCount: number | null
      applicableAvailableCount: number | null
      source: "usage" | "credit_details"
    }>
    resetDetails: Group<{ credits: Credit[] }>
  }
  command: CommandSummary
}
type Status = {
  apiMajor: 1
  appBuild: string
  serverTime: Instant
  timezone: string
  owner: "ready" | "shutting_down"
  inventory: Group<{ count: number; namespaceId: string }>
  recoveryStorage: { available: boolean; error: Fault | null }
}
type AccountsResponse = {
  status: Status
  accounts: Account[]
}
type Schedule = {
  state: "started" | "joined" | "deferred" | "blocked"
  nextAttemptAt: Instant | null
  reason: Fault | null
}
type RefreshRequest = { accountIds?: string[] }
type RefreshResponse = {
  accounts: { accountId: string; schedule: Schedule }[]
  activity: Schedule
}
type Redemption = {
  operationId: string
  accountId: string
  accountName: string
  requestedCreditId: string | null
  selectedCreditId: string | null
  createdAt: Instant
  updatedAt: Instant
  state: "pending" | "confirmed" | "nothing_to_reset" | "no_credit" | "failed" | "unknown"
  providerResult: { code: string; windowsReset: number | null } | null
  error: Fault | null
  acknowledgementRequired: boolean
  acknowledgedAt: Instant | null
  resultUrl: string
}
```

`Group.data = null` with no observation means never observed; with an observation and no error it means successful absence/not applicable. A successfully observed empty list is `[]`. Account list responses may retain last-known inventory under an inventory error; clients must read its freshness. No failed inventory read becomes a successful empty list. `identityColorIndex` is 0 through 5; `pinOrder` is zero-based among pins. `pin.lines` contains zero to two lines and is owner-derived even for unpinned Accounts; zero lines renders `?`. Quota-level stale incorporates its group's stale state and reset passage.

Reset summary prefers a successful dedicated detail observation when available; an embedded usage summary can update count independently when details fail. Keep the selected source and timestamps truthful; never combine counts from different observations into one falsely current group. Details have their own freshness. Applicable null means not reported, distinct from zero. Credit expiry `none` requires affirmative schema interpretation. `available` is derived only from verified status semantics; unknown status is not silently available.

### Routes and responses

| Request | Success body/status |
| --- | --- |
| `GET /status` | `Status`, 200. |
| `GET /accounts` | `AccountsResponse`, 200; display order from section 6. |
| `GET /accounts/{accountId}` | `{ status: Status, account: Account }`, 200. |
| `GET /activity?range=today\|yesterday\|last30days` | `ActivityResponse`, 200; omitted range defaults to Today. |
| `POST /refresh` | `RefreshRequest` body; `RefreshResponse`, 200 after scheduling. Omitted accountIds targets all, empty array requests activity only. Unknown IDs reject the request before scheduling; duplicates collapse. Every valid explicit refresh also requests activity. |
| `POST /accounts/{accountId}/redemptions` | `{ operationId: string, creditId?: string }`; `Redemption`, 202 while pending, otherwise 200. `Location` matches `resultUrl`. UUID is required; omitted credit is automatic. |
| `GET /redemptions/{operationId}` | `Redemption`, 200; reads never send provider mutations. |
| `POST /redemptions/{operationId}/acknowledge` | `{}` body; updated `Redemption`, 200. Repeated acknowledgement of an already acknowledged unknown is idempotent. Other states conflict. |

All route paths above are relative to `/api/v1`. GETs are cached reads and never trigger provider collection or activity scans. Owner-derived freshness, pacing, and pin selection may be recomputed from cached inputs and the clock. Accepted commands remain readable after Account removal.

Errors use `{ error: Fault }`: 400 invalid shape/range/UUID; 403 rejected origin/Host; 404 unknown resource/route; 409 reused UUID with different request, Account block, or invalid acknowledgement; 503 owner cannot accept work, including shutdown or required recovery-storage failure. Use 405 for unsupported methods and 415 for a non-JSON mutation content type. Accepted-operation outcomes are represented by state rather than an HTTP success that implies a reset. Error codes describe the cause, such as `invalid_request`, `account_not_found`, `operation_conflict`, `account_blocked`, `inventory_unavailable`, `credentials_unavailable`, `provider_cooldown`, `recovery_storage_unavailable`, `provider_response_unknown`, and `shutting_down`. Sanitize provider errors.

### Activity DTOs

```ts
type Tokens = {
  input: number
  output: number
  reasoning: number
  cacheRead: number
  cacheWrite: number
  total: number
}
type PricingCoverage = {
  fullyPricedRows: number
  boundedRows: number
  partiallyPricedRows: number
  unpricedRows: number
  missingUsageRows: number
  pricedComponents: Tokens
  unpricedComponents: Tokens
}
type Estimate = {
  status: "scalar" | "range" | "partial" | "unpriced" | "empty"
  currency: "USD"
  lower: Decimal | null
  upper: Decimal | null
  coverage: PricingCoverage
  exclusions: {
    provider: Provider
    modelId: string
    reason: string
    rows: number
    tokens: Tokens | null
  }[]
}
type Aggregate = {
  rows: number
  missingUsageRows: number
  tokens: Tokens | null
  recordedCost: {
    amount: Decimal | null
    currency: "USD"
    rowsWithCost: number
    missingCostRows: number
    ambiguousZeroRows: number
  }
  estimate: Estimate
}
type ActivityData = {
  range: Range
  startAt: Instant
  endAt: Instant
  timezone: string
  source: {
    namespaceId: string
    schemaRevision: string
    attribution: "provider_local_database"
    partialHistory: true
    qualifications: string[]
    firstRetainedAt: Instant | null
    lastRetainedAt: Instant | null
    populatedDays: number
  }
  pricing: {
    revision: string
    observedOn: string
    digest: string
    basis: "standard_global_api_equivalent"
  }
  totals: Aggregate
  providers: {
    provider: Provider
    label: string
    totals: Aggregate
    models: { modelId: string; totals: Aggregate }[]
  }[]
  trend: {
    range: "last30days"
    startAt: Instant
    endAt: Instant
    days: {
      date: string
      startAt: Instant
      endAt: Instant
      selected: boolean
      totals: Aggregate
    }[]
  }
}
type ActivityResponse = {
  status: Status
  activity: Group<ActivityData>
}
```

Activity bounds identify the actual observed range, ending at the captured scan cutoff for current-day data. Trend has exactly 30 calendar buckets; each bucket carries its actual observation interval, with today's end at the cutoff. Provider order follows section 3; model IDs sort lexically. Group variants under their recorded provider/model ID; no alias-based regrouping is necessary for v1.

On a successful empty bucket, rows is zero, token components are measured retained-record sums of zero, and estimate is `empty` with zero bounds; label it "No recorded activity". With rows but no token objects, tokens is null. Partial token coverage has a known subtotal plus missing-usage count. A fully unpriced nonempty bucket has null estimate bounds, never fabricated $0.

Pricing row categories are disjoint and sum to rows: missing usage first; then unpriced if no verified model/rates can price the row; partial if any positive components remain unpriced; bounded if all components are priced with verified alternatives; otherwise fully priced. Priced/unpriced token-component sums cover known token quantities once, excluding missing-usage quantities. Exclusion reasons can overlap and their row counts are not an additive coverage total.

Scalar has equal lower/upper; range has verified unequal bounds; partial has the subtotal bounds for priced components, with exclusions and missing coverage prominent. Its upper is not a bound on the entire activity. If no components can be priced, status is unpriced and bounds null. A model with unverified rates and all-zero components remains unpriced. Recorded cost never fills these fields. Aggregate estimates use one pricing revision and add lower/upper over the same included component set; any exclusions/missing usage make the aggregate partial (or unpriced if nothing is priced).

## 10. OpenCode companion contract

Decided by **Verify OpenCode credential, model-tool, TUI, and context-injection capabilities**, the architecture/API resolutions, and consolidation review.

Register one model tool named `tally` through OpenCode V2's tool registry. It has an action-discriminated input and returns a structured result containing the corresponding REST body. It does not add context hooks, HTTP interception, account attribution, or TUI surfaces. Configure the Tally base URL in the companion; default to the installed app's documented loopback address/port, and allow the independently configured tailnet URL for a remote companion. The tool sees this Mac's Tally inventory regardless of the invoking OpenCode instance.

```ts
type TallyInput =
  | { action: "status" }
  | { action: "accounts"; accountId?: string }
  | { action: "activity"; range?: Range }
  | { action: "refresh"; accountIds?: string[] }
  | { action: "redeem"; accountId: string; operationId: string; creditId?: string }
  | { action: "redemption"; operationId: string }
  | { action: "acknowledge"; operationId: string }
type TallyResult<T> =
  | { ok: true; action: TallyInput["action"]; data: T }
  | { ok: false; action: TallyInput["action"]; error: Fault }
```

`accounts` with no ID lists Accounts; with ID reads one. Other actions map directly to section 9. The implementation's output schema pairs each action with its actual DTO, rather than an unconstrained generic. Preserve freshness, coverage, unknowns, operation ID, and structured error code in the model-visible output. Do not stringify away these distinctions.

The tool description encourages periodic usage queries as the model works. It explains explicit user authorization for every redemption/acknowledgement, clarifying names to opaque IDs, nullable applicability, provider-decided effects, and no-resend recovery. Queries can be automatic model choices; mutations cannot be inferred from general permission to continue.

Redeem returns pending immediately. The model can query `redemption` for progress. Repeated calls use the original operation UUID. On a lost submission response, report uncertainty and the original UUID, then read that operation; never create a replacement UUID automatically. Unknown means ask the user before acknowledgement or a new operation. Connection/version failures return structured errors and do not interrupt model execution beyond that tool result. The companion performs no automatic mutation retry.

## 11. Implementation acceptance and evidence boundary

Derived from all named decisions. These are required implementation checks, not tests run during planning.

| Area | Acceptance cases |
| --- | --- |
| Inventory | Active/inactive inclusion; Zen exclusion; distinct Go keys and OpenAI workspaces; deterministic duplicate names; rename/refresh continuity; replacement/removal; schema failure versus empty; namespace switching; first nonempty batch and later unpinned Accounts; palette stability/repetition. |
| Collection | Two-minute cadence; wake; 60-second explicit minimum; in-flight joining; 2/4/8/15 backoff and Retry-After; rejected-credential blocking; healthy Account independence; activity refresh during provider cooldown. |
| Readings | Successful zero/absence versus unknown; optional-detail failure; last-good restart; cache corruption; five-minute and reset-boundary staleness; no invented resets; valid/invalid pacing including unknown Monthly duration. |
| Presentation | 360px popover; 320/390px phones; 1000px breakpoint; 14-pin reference case; single/stacked/tied/unknown-duration pins; both exact palettes; full-width 4px bars; unknown/Off/used-only/bounded extra usage; Fable-only scoped rows; key/value details; system appearance; failed web polling. |
| Activity | V2 once, known fork-copy exclusion and child requests; Zen exclusion; missing usage/empty scans; exact 30 calendar days and DST; timezone changes; mutable source totals; provider-only attribution; Today totals with 30-day context chart. |
| Pricing | Exact/explicit alias matching; unpriced suffixes; each tier boundary and operator; input/cache disjointness; output/reasoning once; Anthropic/Go bounds; partial unknown components; missing usage; disjoint coverage; empty/unpriced zero distinctions; no mixed revisions or recorded-cost substitution. Use the research's synthetic numeric fixtures. |
| Redemption | Explicit Account/workspace; preflight versus cached count; nullable applicability; expiry ordering; UUID duplicates/conflicts; per-Account concurrency; pre-send storage failure; response loss; unknown result; restart at each durable state; acknowledgement without send; removal/replacement; confirmed result with failed refresh; browser disconnect; bounded Quit. |
| Contracts | Representative JSON fixtures decoded by Swift and TypeScript: all reading states, two pin lines, unknown expiry, positive/null limit, zero/null applicable count, partial estimates, and pending/unknown/acknowledged operations. Check native and REST use the same owner semantics. |
| Packaging | Actual Apple Silicon build and app resources; missing API/assets return proper errors; listener collision/retry; unsigned download/quarantine launch; login startup; manual update/build reload; actual Tailscale assets/API and Origin/Host enforcement; companion version mismatch. |

No Tally runtime, provider call, credential read, or reset redemption ran in this consolidation session. Provider reads, source checks, and static prototype inspection are dated prior evidence in their linked tickets. Plan-specific reset effects and provider replay guarantees remain unverified. Max will try redemption once v1 runs locally; consuming a credit is not a prerequisite to this spec. Source mappings, dependencies, packaging, and fixtures require implementation-time verification.

The implementation may choose internal file layout, storage engine, concrete error-code extensions, and dependency versions within this contract. It must not silently change public behavior or hide uncertainty to make an example pass.

## 12. Explicit supersessions

1. The visual prototype's two stacked eligible durations replace the presentation ticket's single-shortest-value pins. Consolidation retains lowest-remaining tie selection per duration and excludes Monthly, scoped, and unknown-duration windows.
2. Extra usage is visible in the card body, replacing expanded-details-only placement. No positive reported limit means used-only without a bar; a positive limit means remaining-first with a bar.
3. Fable is the only displayed model-specific meter. OpenAI Spark/supplementary model rows are excluded from native/web. Consolidation retains interpretable omitted windows in REST and preserves every account-wide window.
4. Native/web inline confirmation replaces the API ticket's original single-action/no-second-confirmation choice. Pending-disabled controls and "Redeeming…" are retained without a separate progress panel. Companion authorization remains an explicit user request per operation.
5. The prototype's Cards layout and exact mono-first light/dark palette replace provisional layout/palette suggestions. Color appears only on pin/card logos, not general text/bars/chips. Account names remain verbatim from OpenCode.
6. The 30-day chart under Today/Yesterday is now explicitly accepted; selected totals and breakdowns still follow the range. Desktop collapses to one column below 1000 CSS px.
7. Initial pins/colors are assigned at the first successful nonempty inventory, in deterministic provider/name/ID order. Empty/failed discovery does not finish initialization. Database namespaces retain separate preferences.
8. Go Monthly pacing does not adopt OpenUsage's fixed 30-day assumption. "Not started" requires the verified provider mapping and fresh explicit zero, rather than any missing reset timestamp.
9. Unknown credit expiry sorts after confirmed nonexpiring credit for automatic selection and remains distinct in the contract. Applicability never becomes a client-side eligibility gate.
10. Earlier research proposals for proactive context injection, TUI advisories, mixed Go/Zen activity, or retrying consume are superseded by the map's tool-only, Go-only, no-resend decisions. The pricing resolution accepts xAI's specific inclusive threshold rather than leaving its equality point unresolved.
