# OpenCode local activity attribution and coverage

Research for Tally issue 10, inspected 2026-09-06. This is evidence and decision input, not an implementation or a change to accepted scope.

https://github.com/MaxAnderson95/tally/issues/10

## Findings

1. Current OpenCode V2 assistant records support recorded token components, recorded cost, provider/model breakdowns, and local-calendar aggregation. They do **not** retain the producing credential, subscription account/workspace, authentication method, or dispatched request URL. All four Tally providers therefore support a **local database/provider scope**, not proven per-Account activity. Even one currently stored Account does not establish ownership of historical rows. [S1-S3; Q1]
2. The standard `opencode-go` and `opencode` provider IDs have distinct Go and Zen endpoints. Historical records retain those provider IDs, so their labeled activity can be separated without examining or deduplicating API keys. However, the actual request URL is not retained, and configuration/plugins can rewrite it. Strict historical proof that a row used the Go service is unavailable from this database alone. Accepting the recorded `opencode-go` label as the service classification requires an explicit qualification/decision. [S3-S5; Q1-Q2]
3. `cost` is a stored number, but current OpenCode calculates it from normalized tokens and runtime model pricing. It is not a provider invoice or a measured subscription charge. Missing prices become zero, and OpenAI's ChatGPT plugin deliberately removes prices. A stored `$0` cannot establish free activity or complete price coverage. Current bundled catalog lookup also fails for several model IDs present in this Mac's recent history. [S6-S8; Q2, Q5]
4. Summing every assistant row double-counts forked history. The checked database had 192 copied assistant rows in three forks, including 121 whose original parent session no longer existed. V1 and V2 also overlap extensively. Count the V2 projection once, remove known fork copies, include actual child-agent requests, and do not add session totals or event replay rows to assistant totals. [S9-S12; Q3]
5. The database is an editable conversation projection, not a complete activity ledger. Revert deletes messages; session deletion cascades to messages; migration omits paired compaction-summary assistant usage from the V2 message projection. Current title/compaction calls update lifetime session totals, but their usage event lacks provider/model identity, and event payload persistence defaults off. This Mac had zero retained `session.usage.recorded*` events. Exact complete daily/provider/model totals cannot be reconstructed. [S10-S14; Q3-Q4]
6. Today, yesterday, and today plus the preceding 29 days are straightforward calendar windows. The checks used this Mac's `America/New_York` timezone: the 30-day range was August 8 through September 6 inclusive. Absence of retained rows is **no recorded activity**, not proof that no requests occurred. A best-effort cache can preserve its last observed derived view, with its coverage limitations, but cannot recover deleted unobserved requests or missing historical attribution. [Q2-Q4; recommendations below]

## Evidence boundary and prior decisions

Read `AGENTS.md`, `docs/agents/domain.md`, `CONTEXT.md`, `docs/adr/0001-single-app-runtime.md`, `docs/research/PROVIDER-DATA-AND-RESETS.md`, the complete issue 10 REST response, and the resolution comments of issues 4 and 6.

https://github.com/MaxAnderson95/tally/issues/4#issuecomment-5562027035

https://github.com/MaxAnderson95/tally/issues/6#issuecomment-5562523081

**Prior evidence, not repeated:** issue 4's provider endpoint observations and OpenUsage scanner behavior; issue 6's account identity, freshness, cache, calendar-window and service-scope decisions; Max's clarification that two distinct keys each have Go and Zen entries. No provider usage requests, credential reads, refreshes, or redemption occurred in this research. The earlier reference scanner's merging of Go and Zen remains unsuitable for Tally.

**Newly verified:** local upstream source, V2 public troubleshooting documentation, installed CLI version, sanitized live SQLite schema/key inventories and aggregates, fork/migration overlap, pricing lookup availability, and source lifecycle behavior. Queries selected structural fields, model/provider identifiers and numerical aggregates. No credentials, account identifiers, session identifiers, titles, directory values, messages, tool output, or provider-state values are published here. One duplicate check compared JSON internally but emitted only counts.

| Item | Verified revision or boundary |
|---|---|
| Local upstream clone | `/Users/max/.btca/agent/sandbox/opencode-beta`, `anomalyco/opencode` |
| Source revision | `b2cecc6350d377c382e1ec32ee66ec63ad68f715` |
| Freshness check | `git fetch origin beta` succeeded; `git rev-parse HEAD origin/beta` returned that same SHA twice. No checkout or branch change. |
| Installed CLI | `opencode2 --version` returned `opencode2 v0.0.0-beta-19192`. This does not prove a build-to-SHA match. |
| Database | Default `~/.local/share/opencode/opencode.db`, opened with `sqlite3 -readonly`; no live API/server start needed. |
| Observation timing | Multiple read transactions around 22:38-22:52 UTC, September 6. OpenCode remained active, so counts from different transactions can differ. |
| Timezone | `readlink /etc/localtime` returned `/var/db/timezone/zoneinfo/America/New_York`; SQLite local clock was UTC minus four hours. |

The V2 troubleshooting page confirms the default DB path and `OPENCODE_DB` override. Only the default database was inspected; this report does not claim coverage of other OpenCode homes, remote servers, CLI logs or machines.

https://opencode.ai/v2/docs/troubleshooting

## Attribution and Go/Zen separation

### What survives in a request's record

The `session_message` table has `id`, `session_id`, `type`, `seq`, `time_created`, `time_updated`, and JSON `data`. An assistant's model reference has only `providerID`, `id`, and optional `variant`. Its usage belongs to that assistant step, not the session's current/default model. Sessions can change models, so assigning a whole session's lifetime counters to its current model is incorrect. [S1-S3]

The runtime resolves the active integration connection and credential, creates an authenticated runtime model, and returns a separate small model reference. It records that reference in the assistant start event. The reference does not carry the resolved credential or route. `session_v2.workspace_id` is an OpenCode execution Location workspace, not the ChatGPT workspace selected by `metadata.accountID`. Directory/project identity likewise does not prove who paid for a request. [S2-S3]

The live key inventory found no assistant-level or model-level credential/account/workspace fields, no stored base URL, and no assistant `metadata`. `providerState` had only the keys `responseId` and `serviceTier`; values were not read. A response ID or service tier does not establish account ownership. The generic provider-state schema is not a documented billing identity contract. [S1; Q1, Q4]

Credential rename/refresh updates the credential row; removal deletes it. Credential switch events are ephemeral. Historical assistant records have no credential foreign key, no frozen account identity and no credential-change history with which to reconstruct attribution. Removing or rotating credentials therefore leaves the provider/model references intact but cannot preserve an Account association that was never recorded. Historical rows may also include API-key or environment-backed requests even when the current inventory contains only OAuth subscriptions. [S2-S3, S8]

### Per-provider display scope

| Provider | Supported association for retained assistant usage | Unsupported association |
|---|---|---|
| Anthropic | Recorded provider `anthropic`, recorded model/variant, local DB | Individual Claude Account, organization or historical subscription-versus-API authentication |
| OpenAI | Recorded provider `openai`, recorded model/variant, local DB | Personal versus Work, historical ChatGPT workspace, API key versus subscription |
| OpenCode Go | Recorded provider `opencode-go`, model/variant, local DB, with service-label qualification | Either of the two Go Accounts; strict proof of historical dispatch URL or subscription billing source |
| xAI/Grok | Recorded provider `xai`, model/variant, local DB | Individual Grok Account or historical subscription-versus-API authentication |

Show a provider-scoped local activity view once. Do not attach the same total to each Account, divide it equally, or assign it to whichever Account is active now. Removed-account contributions cannot be identified and subtracted from these provider totals. This needs to remain visible as a distinction between the current Account inventory and local historical provider activity.

### Service selection is independent of key reuse

New source checks establish:

- The bundled catalog maps `opencode-go` to `https://opencode.ai/zen/go/v1` and `opencode` to `https://opencode.ai/zen/v1`. Catalog normalization turns those API values into `settings.baseURL`. [S4]
- The first-party Go chat-completions route selects `modelList: "lite"`; the Zen route selects `modelList: "full"`. Both parse the same Authorization key shape. The Go billing branch checks weekly, monthly and rolling limits. [S5]
- Request hooks can change the base URL and HTTP request before dispatch. Provider/model settings can also change routing. None of that effective URL is in `Model.Ref`. A historical provider label is therefore evidence of the selected OpenCode provider, not a network audit. [S1, S3-S5]
- The server can fall back to balance when Go's `useBalance` policy allows it. Thus even a proven Go endpoint request would not establish that its cost consumed Go quota. Local activity and provider quota must stay separate. This is source behavior, not a live check of Max's account setting. [S5]

For a provider-label policy, filter `providerID = 'opencode-go'` and exclude `opencode` before any aggregation. Do not classify by model family: a Grok model selected through Go remains Go-provider activity, and a Zen model remains excluded. Do not collapse the two Go Accounts because the same service also accepts their keys for Zen.

**Decision needed:** approve the explicitly qualified "OpenCode Go provider activity" interpretation for historical `opencode-go` rows, or require actual-service proof and mark that historical service total unavailable. No read-only scan of these records can meet the stronger proof requirement. Future request-time capture would require a separate, approved change and would not repair old rows.

## Tokens and costs

### Token provenance

Current `SessionUsage.tokens()` normalizes provider/SDK usage into five components: noncached input, visible output, reasoning output, cache-read input, and cache-write input. OpenCode's `TokenUsage.total()` adds those five. Keep the components so a total has a defined meaning; it measures repeated request processing, including reused cached context, not unique words written or conversation size. [S6]

Missing, nonfinite and negative component values normalize to zero upstream. This erases the distinction between a provider that explicitly reported zero and a provider that omitted a component. An entire absent `tokens` object is still detectable. The live check found 357 assistant rows without usage, with no partially missing component fields among present token objects. Do not coerce the absent object to a measured zero. A failed assistant may still have valid recorded usage; include that usage and retain its error/coverage status. Conversely, an interrupted stream can incur provider work without a final usage record. [S6, S10; Q1, Q3]

Migrated V1 assistant token values are copied into the V2 shape. This research verified that migration, not the normalization behavior of every historical OpenCode version represented in the database. Present historical totals as OpenCode-recorded token totals, rather than asserting independently audited provider billing token counts. [S12]

### Recorded amount versus estimated amount

Current OpenCode's formula is:

```text
context = input + cacheRead + cacheWrite
costUSD = (input * inputPrice
         + (output + reasoning) * outputPrice
         + cacheRead * cacheReadPrice
         + cacheWrite * cacheWritePrice) / 1,000,000
```

It uses the highest qualifying context tier where `context > tier.size`, or the base price. With no applicable price it returns zero. Catalog normalization defaults absent price components to zero. Runtime plugins/configuration can supply different prices; ChatGPT OAuth explicitly sets `draft.cost = []`. The message stores the resulting number, not the price table, price revision, billing currency response, credential or reason for zero. [S6-S8]

Use separate descriptions:

- **OpenCode-recorded cost:** preserves what OpenCode stored. For current V2 it is a locally computed runtime-price amount, and older migrated values retain their older provenance. It is not a provider-reported charge. Zero has ambiguous pricing provenance.
- **Estimated API-equivalent cost:** Tally would compute this using an identified price source/revision and the recorded components. An explicit current-price estimate is possible where a verified model/price match exists; historical effective prices cannot be recovered from these rows alone.
- **Unpriced activity:** keep token totals and model rows when a price/model match is unavailable. Show an unpriced count/token amount and a partial-cost status. Do not silently use another model's price, infer prices from the model name, or call a partial sum complete spend.

The live catalog cross-check found missing exact model entries for recent Anthropic, OpenAI, Go and xAI activity. Some missing-catalog Go/xAI models nevertheless had positive recorded costs. Consequently, "not in today's catalog" does not erase an existing recorded amount, and "recorded zero" does not mean today's catalog would price it at zero. See Q5 for names, counts and the exact lookup. No replacement pricing source or canonical alias mapping was verified here.

Cross-provider recorded cost sums are arithmetically possible, but combine zeroed subscription prices and other runtime estimates. If shown, label them as recorded amounts with incomplete pricing provenance. For an API-equivalent cross-provider estimate, use a coherent pricing policy, keep unknown contributions explicit, and calculate any aggregate cost/MTok from the same priced subset and token definition. Do not average provider ratios or divide a partial cost sum by all providers' tokens without stating that mismatch.

## Duplicate avoidance and coverage

### Projection, fork, replay and import rules

`session_message.id` is a primary key; `(session_id, seq)` is unique. Normal streaming updates replace a message projection rather than producing independent usage rows. The durable bus applies replay sequence checks. These facts support treating a projected assistant ID as one current observation, not adding its cost on every poll. Do not count event versions of the same step in addition to its projection. [S1, S9-S11]

V2 forks copy settled historical messages with new IDs but unchanged JSON, sequence and timestamps; the fork's lifetime counters start at zero. The current upstream stats implementation excludes rows when a forked session has `message.time_created < session.time_created`. The SQL in this report uses that same filter. The live check found 192 such assistants, zero equality-boundary assistants, and no duplicate `(session_id, seq)` groups. [S9; Q3]

This timestamp rule is useful for normal V2 forks, not a universal request identity. Imported/arbitrarily modified timestamps, same-millisecond boundary cases, or old forks without lineage need ambiguity handling. Where the parent and boundary exist, lineage/sequence can validate the copied prefix. Do not use a token/cost/model fingerprint as a universal dedup key: distinct requests can share all those values. A provider response ID is optional and was not verified as a universal cross-provider identity.

The checked fork copies included 121 rows whose parent session was gone. Excluding them avoids double counting but loses the surviving copy as historical evidence; recovering one canonical copy per original request across deleted parents and nested forks requires additional lineage logic and tests. The report's numerical totals intentionally describe the retained non-copied projection, not such recovery. This limitation must accompany coverage, rather than claiming exact all-time completeness.

Child/subagent sessions contain real extra requests and should contribute once. Do not exclude all `parent_id` sessions to solve fork duplication: `parent_id` and `fork_session_id` are different relationships.

The migration preserves ordinary assistant IDs. At the checked instant, 115,768 legacy assistant IDs also existed in V2, so a raw V1+V2 union would massively inflate totals. V1 leftovers are not automatically new coverage: 40 V1-only sessions could include sessions subsequently removed from V2. Import retains IDs and rejects an existing session ID, but also places externally originated history into a local DB without a durable machine-of-origin field. "Local database activity" is a stricter claim than "all of these requests physically ran on this Mac." [S12-S13; Q3]

### Exact history gaps

| Mechanism | Consequence |
|---|---|
| Normal session deletion | Cascades to message rows. No reconstruction from the selected projection afterward. [S1, S10] |
| Committed revert | Deletes the projection at/after a sequence boundary without subtracting lifetime session usage. Current retained transcript totals can decrease even though real usage happened. [S10] |
| V1 compaction migration | Replaces paired summary assistants with compaction messages that omit usage; lifetime session totals still sum the old assistants. [S12] |
| V2 title and compaction generation | Emits internal `UsageRecorded` with session, source, tokens and cost, but no provider/model. Adds to session totals. [S14] |
| Default event persistence | `persist` defaults to false. Projection/sequence commits still happen; historical event payloads need not remain. This Mac had no usage events. [S11, Q1] |
| Missing final usage / failed requests | No provider bill reconciliation is possible from absent or normalized-zero usage. [S6, S10] |
| Imported records | No trustworthy historical machine origin in the selected schema. [S13] |

Do not repair these gaps by subtracting assistant sums from session sums and assigning the difference to the session's latest model or latest day. At 22:42:24 UTC, 418 nonfork sessions had different lifetime versus assistant token totals, with a net difference of 31,760,400 tokens; 57 differed in cost, net $24.495172. That establishes a real mismatch, not that every difference was compaction, title generation or any particular provider. [Q3]

Upstream `SessionStats.get` also cannot supply the missing contract: it aggregates provider/model assistant usage with the fork filter, its daily activity counts steps rather than tokens, and its separate compaction-event addition changes overall totals without assigning those costs/tokens to models. It excludes title usage. Its existence does not establish complete Tally daily/provider costs. [S15]

**Recommended source boundary, pending acceptance:** retained, non-copied V2 assistant usage in the selected local database, including migrated ordinary assistants and child requests; all four supported provider IDs, with the stated Go classification qualification. Preserve known missing-usage counts and source limitations. Do not silently add legacy remnants, CLI logs, events or session-total differences. Complete history would require broader recovery/instrumentation work and still could not backfill erased records.

## Calendar windows, trends and zero

Use this Mac's current timezone for all three ranges and daily buckets:

- Today: local start of today through the current observation, displayed within today's calendar bucket.
- Yesterday: local start of yesterday up to, but excluding, local start of today.
- Last 30 days: local start of today minus 29 calendar days through the current observation, displayed as exactly 30 daily buckets.

The calendar bins end at the next local midnight; source scanning should also exclude future timestamps and use one captured observation time. Use half-open `[start, end)` bounds. The SQL checks used local date buckets through tomorrow's exclusive midnight; a separate query found zero future assistant timestamps. Do not subtract `30 * 86,400` seconds or copy the reference's 31-day display. DST days can contain 23 or 25 hours. In Swift, derive boundaries by calendar day addition in the selected timezone, then compare epoch milliseconds. Calendar/DST runtime tests for a future implementation did not run here.

Use assistant `time_created` as the activity timestamp, matching upstream stats and the stored JSON creation time. Completion or `time_updated` would move old usage when tools settle or projections change. A request spanning midnight is assigned wholly to its creation day; the database cannot allocate tokens within a request across both days. Active requests without usage remain pending/missing, not zero. A timezone change requires rebucketing source timestamps, not relabeling previously cached daily sums.

Daily trend and model totals can use the same filtered rows and sum the same token components. Group on the recorded `(providerID, model.id)` and optionally `variant`; do not substitute session defaults, current model aliases, or model marketing names for stable recorded IDs. Sum the four provider groups once for cross-provider totals and exclude `opencode` and other providers before aggregation.

Useful distinctions for the presentation decision:

| State | Honest display meaning |
|---|---|
| Successful compatible scan, no matching rows in a bucket | "No recorded activity" or numeric 0 explicitly scoped to retained records; not confirmed no usage |
| Present usage object whose recorded components sum to zero | Recorded zero-token row; upstream may have defaulted missing provider components to zero |
| Rows exist but some lack usage | Partial token total plus missing/pending usage status |
| Price unavailable or recorded zero of unknown origin | Tokens available; cost unpriced/partial or recorded-zero-with-unknown-provenance |
| Database missing, unreadable or incompatible | Unavailable/error; retain previous cached view as stale |
| Source coverage before oldest retained record, deleted/reverted history, lost fork ancestry | Unknown completeness, not a continuous verified zero interval |

At the range check, Anthropic had rows on 28 of the 30 days, OpenAI on 25, Go on 12, and xAI on two. Yesterday had OpenAI and Go rows but no Anthropic/xAI rows. Those absent days are not proof of zero activity. First/last retained timestamps and a count of populated days describe observed coverage; they cannot certify continuity between those dates. [Q2]

## Best-effort derived cache

This recommendation follows issue 6's single-owner, last-good, nonarchival policy:

1. Cache the last successful derived view with observation time, source identity/schema compatibility, timezone, window bounds, attribution scope, token components, model breakdowns, cost provenance/pricing revision and coverage/missing counts. Restore it as stale. Do not stamp provider-scoped data with the currently active Account.
2. A successful rescan replaces the matching derived view; failed reads retain it with the failure and last-success timestamp. Polling must be idempotent. Repeatedly adding message totals or summing old and new snapshots double-counts usage.
3. Rebuild from retained source when available. A bounded per-record normalized cache could preserve timestamps needed for rebucketing and in-flight updates, but is an implementation choice, not a requirement for a full history database. Keep mutable observations replaceable by source ID; do not treat session counters as daily deltas.
4. A daily-only cache can recover the old rendered range after restart, but cannot exactly re-bucket a timezone change or resolve a changed/deleted source row. If retained data cannot be reconciled, expose the cached result as stale with its original timezone/range. Do not silently blend incompatible buckets.
5. Source deletion/revert may reduce a fresh reconstructible total. A last-good cache can preserve an earlier observation as stale evidence but does not guarantee a permanent archive. Distinguish a successful empty scan from a failed scan; neither grants knowledge of historical completeness.

Account-specific quota cache removal/identity continuity stays as decided in issue 6. These unattributed provider totals cannot implement removal of one Account's historical contributions. Do not pretend that deleting a current Account proves which provider rows should be removed. Any request-time Account stamp or independently retained ledger is additional scope requiring approval.

## Acceptance assessment and decisions for the parent

| Requested display/requirement | Evidence-supported result | Decision or limitation to expose |
|---|---|---|
| Token totals for all four providers | Yes, retained assistant records, components and partial-usage counts | Accept explicitly partial local-record coverage |
| Recorded cost | Yes, numerical values exist | Label local runtime-price provenance; zero is ambiguous |
| API-equivalent estimated cost | Feasible for verified priced models | Choose pricing source/version and alias policy; unknown models remain unpriced |
| Model breakdown | Yes, recorded provider/model/variant | Excludes usage without model attribution; current catalog is incomplete |
| Today/yesterday/30 local days | Yes, creation-time calendar bins | Exactly today plus 29 days; timezone/DST rebucketing and missing coverage need tests |
| Daily token trend | Yes for the selected rows | Empty source bucket is no recorded activity, not verified zero |
| Cross-provider totals | Yes for the same four filtered groups once | Same partial scope; no Zen, duplicate Account cards, or unattributed overhead allocated to providers |
| Per-Account or subscription-workspace attribution | No, for all four providers | Use provider/local-DB scope, already permitted by issue 6; cannot separate removed Accounts or authentication modes |
| Historical Go/Zen separation | Yes by recorded canonical provider label; no strict dispatched-URL proof | Explicitly accept label-based classification or mark strict historical Go service totals unavailable |
| Duplicate-free complete historical accounting | Normal V2 projection/fork filtering supported; complete recovery not established | Missing fork ancestry, imports, legacy forks and deleted/reverted data prevent a universal completeness claim |
| Best-effort restart recovery | Last observed derived view is cacheable | Cannot reconstruct information that source never recorded or no longer retains |

The important unresolved product choice is whether "local activity" means the qualified retained-assistant/provider view above or requires complete model requests and proven service routing. The latter cannot be delivered by the accepted read-only DB approach alone. Keep every requested display in scope while exposing partial/unavailable data; do not call this research permission to omit unsupported displays silently.

## Sanitized SQL checks and results

These are read-only investigative queries, not production scanner code. Each command used `sqlite3 -readonly` against the default DB; multi-query snapshots used `BEGIN; ... COMMIT;`. Outputs below deliberately omit identity-bearing values. Counts can advance between blocks while OpenCode is running.

### Q1: Schema, JSON shape and identity absence

```sql
SELECT name, type FROM pragma_table_info('session_message');
SELECT k.key, count(*) AS rows
FROM session_message m, json_each(m.data) k
WHERE m.type = 'assistant' GROUP BY k.key;
SELECT k.key, count(*) AS rows
FROM session_message m, json_each(m.data, '$.model') k
WHERE m.type = 'assistant' GROUP BY k.key;
SELECT k.key, count(*) AS rows
FROM session_message m, json_each(m.data, '$.providerState') k
WHERE m.type = 'assistant' GROUP BY k.key;
SELECT count(*) AS rows,
 sum(json_type(data,'$.credentialID') IS NOT NULL
  OR json_type(data,'$.accountID') IS NOT NULL
  OR json_type(data,'$.workspaceID') IS NOT NULL) AS top_identity_rows,
 sum(json_type(data,'$.model.credentialID') IS NOT NULL
  OR json_type(data,'$.model.accountID') IS NOT NULL
  OR json_type(data,'$.model.workspaceID') IS NOT NULL) AS model_identity_rows,
 sum(json_type(data,'$.baseURL') IS NOT NULL
  OR json_type(data,'$.model.baseURL') IS NOT NULL) AS endpoint_rows,
 sum(json_type(data,'$.tokens') IS NULL) AS missing_tokens,
 sum(json_type(data,'$.cost') IS NULL) AS missing_cost,
 sum(json_type(data,'$.time.completed') IS NULL) AS unfinished,
 sum(json_type(data,'$.error') IS NOT NULL) AS errors,
 sum(json_type(data,'$.retry') IS NOT NULL) AS retries
FROM session_message WHERE type='assistant';
SELECT count(*) AS compactions,
 sum(json_type(data,'$.model') IS NOT NULL) AS with_model,
 sum(json_type(data,'$.tokens') IS NOT NULL) AS with_tokens,
 sum(json_type(data,'$.cost') IS NOT NULL) AS with_cost
FROM session_message WHERE type='compaction';
SELECT count(*) AS usage_events
FROM event WHERE type LIKE 'session.usage.recorded%';
```

Results: columns `id TEXT`, `session_id TEXT`, `type TEXT`, `seq INTEGER`, `time_created INTEGER`, `time_updated INTEGER`, `data TEXT`. Assistant top-level keys were `agent`, `content`, `cost`, `error`, `finish`, `model`, `providerState`, `rawFinish`, `retry`, `snapshot`, `time`, `tokens`; model keys only `id`, `providerID`, `variant`. Provider-state keys only `responseId` and `serviceTier`. At 22:41:01 UTC: 135,484 assistants; top/model identity rows 0/0; endpoint rows 0; missing tokens/cost 357/357; unfinished 104; error rows 2,021; retry rows 105. All 186 compaction rows lacked model, tokens and cost. Usage events: 0. This is evidence about the inspected schema/keys, not a search for private identifiers hidden in conversation text.

### Q2: Calendar/provider totals and observed coverage

```sql
WITH a AS (
 SELECT m.*, s.fork_session_id, s.time_created AS session_created
 FROM session_message m JOIN session_v2 s ON s.id=m.session_id
 WHERE m.type='assistant'
), kept AS (
 SELECT *, json_extract(data,'$.model.providerID') AS provider,
  json_extract(data,'$.tokens.input')
  + json_extract(data,'$.tokens.output')
  + json_extract(data,'$.tokens.reasoning')
  + json_extract(data,'$.tokens.cache.read')
  + json_extract(data,'$.tokens.cache.write') AS tokens,
  date(time_created/1000,'unixepoch','localtime') AS day
 FROM a WHERE fork_session_id IS NULL OR time_created>=session_created
), windows(name,start_day,end_day) AS (
 VALUES ('today',date('now','localtime'),date('now','localtime','+1 day')),
 ('yesterday',date('now','localtime','-1 day'),date('now','localtime')),
 ('30 days',date('now','localtime','-29 days'),date('now','localtime','+1 day'))
)
SELECT w.name,w.start_day,w.end_day,k.provider,count(*) AS rows,
 count(tokens) AS token_rows,sum(tokens) AS tokens,
 round(sum(json_extract(data,'$.cost')),6) AS recorded_usd,
 count(DISTINCT day) AS days_with_rows
FROM windows w JOIN kept k ON k.day>=w.start_day AND k.day<w.end_day
WHERE provider IN ('anthropic','openai','opencode-go','xai')
GROUP BY w.name,k.provider ORDER BY w.name,k.provider;
```

| Range | Provider | Rows / with tokens | Tokens | Recorded USD | Days with rows |
|---|---|---:|---:|---:|---:|
| 30 days | Anthropic | 14,808 / 14,655 | 2,427,198,558 | 1,228.266406 | 28 |
| 30 days | OpenAI | 9,251 / 9,114 | 1,459,629,471 | 0 | 25 |
| 30 days | Go label | 1,537 / 1,496 | 131,575,667 | 43.699068 | 12 |
| 30 days | xAI | 11 / 11 | 560,754 | 0.653136 | 2 |
| Today | Anthropic | 585 / 578 | 77,363,001 | 0 | 1 |
| Today | OpenAI | 280 / 274 | 16,785,813 | 0 | 1 |
| Today | Go label | 11 / 10 | 222,995 | 0.005291 | 1 |
| Today | xAI | 3 / 3 | 73,963 | 0.091746 | 1 |
| Yesterday | OpenAI | 86 / 81 | 13,704,909 | 0 | 1 |
| Yesterday | Go label | 2 / 2 | 401,199 | 0.018134 | 1 |

The 30-day bounds returned `2026-08-08` and exclusive `2026-09-07`; today `2026-09-06` to `2026-09-07`; yesterday `2026-09-05` to `2026-09-06`. The inner join emits no Anthropic/xAI row for yesterday, intentionally distinguishing no retained rows from a measured row.

The all-history coverage query used the same `a`/fork filter and grouped the retained provider records:

```sql
WITH kept AS (
 SELECT m.*, json_extract(m.data,'$.model.providerID') AS provider
 FROM session_message m JOIN session_v2 s ON s.id=m.session_id
 WHERE m.type='assistant'
  AND (s.fork_session_id IS NULL OR m.time_created>=s.time_created)
)
SELECT provider,count(*) AS rows,
 count(DISTINCT json_extract(data,'$.model.id')) AS models,
 sum(json_type(data,'$.tokens') IS NULL) AS missing_tokens,
 sum(json_extract(data,'$.cost')=0) AS zero_cost_rows,
 round(sum(json_extract(data,'$.cost')),6) AS recorded_usd,
 date(min(time_created)/1000,'unixepoch','localtime') AS first_day,
 date(max(time_created)/1000,'unixepoch','localtime') AS last_day
FROM kept WHERE provider IN ('anthropic','openai','opencode-go','opencode','xai')
GROUP BY provider;
```

| Provider | Retained rows | Models | Missing tokens | Zero-cost rows | Recorded USD | First day through last day |
|---|---:|---:|---:|---:|---:|---|
| Anthropic | 90,853 | 14 | 153 | 38,780 | 10,219.870611 | 2025-12-30 through 2026-09-06 |
| OpenAI | 30,898 | 21 | 137 | 30,761 | 0 | 2026-02-06 through 2026-09-06 |
| Go label | 4,133 | 13 | 41 | 149 | 87.301098 | 2026-04-10 through 2026-09-06 |
| Zen label, excluded | 444 | 10 | 5 | 188 | 28.117383 | 2026-01-15 through 2026-09-06 |
| xAI | 48 | 2 | 0 | 0 | 1.857752 | 2026-07-23 through 2026-09-06 |

These dates describe oldest/newest surviving records, not guaranteed coverage start/end. Daily trend derivation uses `GROUP BY provider, day` over the same `kept` rows; no chart implementation or visual check ran.

### Q3: Forks, legacy overlap, mutable history and completeness

```sql
SELECT count(*) AS sessions, sum(fork_session_id IS NOT NULL) AS forks,
 sum(parent_id IS NOT NULL) AS children FROM session_v2;
SELECT count(*) AS duplicate_groups FROM (
 SELECT session_id,seq,count(*) AS c FROM session_message
 GROUP BY session_id,seq HAVING c>1
);
SELECT sum(m.time_created<s.time_created) AS copied_rows,
 sum(m.time_created>=s.time_created) AS own_rows,
 sum(m.time_created=s.time_created) AS equal_time_rows
FROM session_message m JOIN session_v2 s ON s.id=m.session_id
WHERE s.fork_session_id IS NOT NULL AND m.type='assistant';
SELECT count(*) AS copied_assistants,
 sum(EXISTS (SELECT 1 FROM session_message p
  WHERE p.session_id=s.fork_session_id AND p.seq=m.seq AND p.data=m.data)) AS identical_parent_rows,
 sum(s.fork_session_id NOT IN (SELECT id FROM session_v2)) AS missing_parent_rows
FROM session_message m JOIN session_v2 s ON s.id=m.session_id
WHERE m.type='assistant' AND s.fork_session_id IS NOT NULL AND m.time_created<s.time_created;
SELECT count(*) AS legacy_sessions,
 (SELECT count(*) FROM session s JOIN session_v2 v ON v.id=s.id) AS overlapping_sessions
FROM session;
SELECT count(*) AS legacy_assistants,
 (SELECT count(*) FROM message m JOIN session_message v ON v.id=m.id
  WHERE json_extract(m.data,'$.role')='assistant') AS overlapping_assistants
FROM message WHERE json_extract(data,'$.role')='assistant';
SELECT count(*) AS legacy_only_sessions,
 (SELECT count(*) FROM message m WHERE json_extract(m.data,'$.role')='assistant'
  AND NOT EXISTS (SELECT 1 FROM session_v2 s WHERE s.id=m.session_id)) AS legacy_only_assistants
FROM session s WHERE NOT EXISTS (SELECT 1 FROM session_v2 v WHERE v.id=s.id);
WITH m AS (
 SELECT session_id,
  sum(coalesce(json_extract(data,'$.tokens.input'),0)
   +coalesce(json_extract(data,'$.tokens.output'),0)
   +coalesce(json_extract(data,'$.tokens.reasoning'),0)
   +coalesce(json_extract(data,'$.tokens.cache.read'),0)
   +coalesce(json_extract(data,'$.tokens.cache.write'),0)) AS tokens,
  sum(coalesce(json_extract(data,'$.cost'),0)) AS cost
 FROM session_message WHERE type='assistant' GROUP BY session_id
)
SELECT count(*) AS sessions_compared,
 sum(abs(s.cost-coalesce(m.cost,0))>0.000001) AS cost_mismatch_sessions,
 sum(s.tokens_input+s.tokens_output+s.tokens_reasoning+s.tokens_cache_read+s.tokens_cache_write
  !=coalesce(m.tokens,0)) AS token_mismatch_sessions,
 sum(s.tokens_input+s.tokens_output+s.tokens_reasoning+s.tokens_cache_read+s.tokens_cache_write
  -coalesce(m.tokens,0)) AS net_extra_session_tokens,
 round(sum(s.cost-coalesce(m.cost,0)),6) AS net_extra_session_usd
FROM session_v2 s LEFT JOIN m ON m.session_id=s.id WHERE s.fork_session_id IS NULL;
SELECT sum(json_type(data,'$.tokens')='object' AND (
 json_type(data,'$.tokens.input') IS NULL OR json_type(data,'$.tokens.output') IS NULL
 OR json_type(data,'$.tokens.reasoning') IS NULL OR json_type(data,'$.tokens.cache.read') IS NULL
 OR json_type(data,'$.tokens.cache.write') IS NULL)) AS incomplete_token_objects,
 sum(time_created!=json_extract(data,'$.time.created')) AS timestamp_mismatches,
 sum(time_created>unixepoch('now')*1000+1000) AS future_rows
FROM session_message WHERE type='assistant';
```

Results: 4,122 sessions, three forks, 1,610 children; zero duplicate groups; 192 copied/282 own fork assistants, zero equality rows; 71 identical parent copies and 121 missing-parent copies. Legacy: 3,569 sessions, 3,529 overlapping; 116,588 assistants, 115,768 overlapping; 40 V1-only sessions with 291 assistants. Nonfork lifetime comparison at 22:42:24 UTC: 4,119 sessions compared, 57 cost mismatches, 418 token mismatches, net extra 31,760,400 tokens/$24.495172. Incomplete token objects, creation-time mismatches and future rows all zero.

### Q4: Missing legacy projection and cross-provider sum

```sql
SELECT count(*) AS legacy_missing_projection,
 sum(json_extract(m.data,'$.summary')=1) AS summary_rows,
 sum(EXISTS(SELECT 1 FROM session_v2 v WHERE v.id=m.session_id)) AS in_v2_sessions
FROM message m WHERE json_extract(m.data,'$.role')='assistant'
 AND NOT EXISTS(SELECT 1 FROM session_message v WHERE v.id=m.id);
SELECT count(*) AS assistant_metadata_rows FROM session_message m
WHERE m.type='assistant' AND json_type(m.data,'$.metadata') IS NOT NULL;
WITH k AS (
 SELECT json_extract(m.data,'$.model.providerID') AS provider,m.time_created,
  json_extract(m.data,'$.tokens.input')+json_extract(m.data,'$.tokens.output')
  +json_extract(m.data,'$.tokens.reasoning')+json_extract(m.data,'$.tokens.cache.read')
  +json_extract(m.data,'$.tokens.cache.write') AS tokens,json_extract(m.data,'$.cost') AS cost
 FROM session_message m JOIN session_v2 s ON s.id=m.session_id
 WHERE m.type='assistant' AND (s.fork_session_id IS NULL OR m.time_created>=s.time_created)
), w(name,start_day,end_day) AS (
 VALUES ('today',date('now','localtime'),date('now','localtime','+1 day')),
 ('yesterday',date('now','localtime','-1 day'),date('now','localtime')),
 ('30 days',date('now','localtime','-29 days'),date('now','localtime','+1 day'))
)
SELECT w.name,count(*) AS rows,count(tokens) AS measured_rows,
 sum(tokens) AS tokens,round(sum(cost),6) AS recorded_usd
FROM w JOIN k ON date(k.time_created/1000,'unixepoch','localtime')>=w.start_day
 AND date(k.time_created/1000,'unixepoch','localtime')<w.end_day
WHERE provider IN ('anthropic','openai','opencode-go','xai') GROUP BY w.name;
```

At 22:43:41 UTC, 820 legacy assistants lacked matching V2 message IDs: 170 summary rows; 529 were in sessions that existed in V2. These categories overlap and are not a recoverable additive total. Assistant metadata rows: zero.

Cross-provider result: 30 days, 25,620 rows/25,289 with tokens, 4,020,778,662 tokens, $1,272.618610 recorded; today, 892/878, 96,259,984 tokens, $0.097037; yesterday, 88/83, 14,106,108 tokens, $0.018134. This later snapshot includes ongoing work after Q2. Every amount has the partial/provenance limits described above.

### Q5: Exact recent model-to-catalog pricing availability

The following query ran through `sqlite3 -readonly -json`, followed by the shown `jq` lookup against the immutable checkout's bundled catalog. Positional grouping avoids collision with `session_v2.model`.

```sql
SELECT json_extract(m.data,'$.model.providerID') AS provider,
 json_extract(m.data,'$.model.id') AS model,count(*) AS rows,
 sum(json_extract(m.data,'$.tokens.input')+json_extract(m.data,'$.tokens.output')
  +json_extract(m.data,'$.tokens.reasoning')+json_extract(m.data,'$.tokens.cache.read')
  +json_extract(m.data,'$.tokens.cache.write')) AS tokens,
 round(sum(json_extract(m.data,'$.cost')),6) AS recorded_usd
FROM session_message m JOIN session_v2 s ON s.id=m.session_id
WHERE m.type='assistant' AND (s.fork_session_id IS NULL OR m.time_created>=s.time_created)
 AND date(m.time_created/1000,'unixepoch','localtime')>=date('now','localtime','-29 days')
 AND date(m.time_created/1000,'unixepoch','localtime')<date('now','localtime','+1 day')
 AND json_extract(m.data,'$.model.providerID') IN ('anthropic','openai','opencode-go','xai')
GROUP BY 1,2 ORDER BY 1,2;
```

```sh
jq --slurpfile catalog /Users/max/.btca/agent/sandbox/opencode-beta/packages/core/src/models-dev/snapshot.txt \
 'map(. + {
  catalog_model_present: ($catalog[0][.provider].models[.model] != null),
  catalog_cost_present: ($catalog[0][.provider].models[.model].cost != null)
 })'
```

Exact entries absent in both model and cost lookup: `anthropic/claude-fable-5-1` (893 rows, 110,928,986 tokens, recorded $0); `openai/gpt-5.6-sol-fast` (5, 159,990, $0); `openai/gpt-6-astra` (368, 24,256,134, $0); `opencode-go/glm-5.3` (974, 101,150,844, $33.011994); `opencode-go/glm-5.3-flash` (294, 16,469,383, $0.370649); `opencode-go/ox-alpha-free` (56, 2,417,781, $0); `xai/grok-4.6` (11, 560,754, $0.653136). Other returned provider/model pairs had a catalog model and cost object. This checks bundled exact-key availability, not whether remote/current or configured prices exist, nor whether a suffix is a verified alias. No price estimate was generated.

### Q6: Exactly 30 daily buckets without inventing measured zero

```sql
WITH RECURSIVE days(day) AS (
 SELECT date('now','localtime','-29 days')
 UNION ALL SELECT date(day,'+1 day') FROM days WHERE day<date('now','localtime')
), providers(provider) AS (VALUES ('anthropic'),('openai'),('opencode-go'),('xai')),
activity AS (
 SELECT json_extract(m.data,'$.model.providerID') AS provider,
 date(m.time_created/1000,'unixepoch','localtime') AS day,
 count(*) AS rows,
 sum(json_extract(m.data,'$.tokens.input')+json_extract(m.data,'$.tokens.output')
 +json_extract(m.data,'$.tokens.reasoning')+json_extract(m.data,'$.tokens.cache.read')
 +json_extract(m.data,'$.tokens.cache.write')) AS tokens
 FROM session_message m JOIN session_v2 s ON s.id=m.session_id
 WHERE m.type='assistant' AND (s.fork_session_id IS NULL OR m.time_created>=s.time_created)
 GROUP BY 1,2
)
SELECT p.provider,count(*) AS calendar_buckets,min(d.day) AS first_day,max(d.day) AS last_day,
 sum(a.rows IS NULL) AS no_record_buckets,sum(a.rows IS NOT NULL) AS populated_buckets
FROM days d CROSS JOIN providers p LEFT JOIN activity a ON a.provider=p.provider AND a.day=d.day
GROUP BY p.provider;
```

Each provider returned 30 buckets, August 8 through September 6. No-record/populated buckets: Anthropic 2/28, OpenAI 5/25, Go 18/12, xAI 28/2. The missing-side join remains null rather than manufacturing a measured token reading. This verifies the calendar scaffold and daily grouping; it does not establish complete source coverage.

## Immutable source index

All links below identify the inspected revision. Line ranges refer to that revision.

- **S1:** Assistant shape `session-message.ts:210-235`, generic metadata/provider state `31-39`; model reference `model.ts:14-18`; message table and uniqueness `session/sql.ts:79-98`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/schema/src/session-message.ts#L210-L235

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/schema/src/model.ts#L14-L18

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/session/sql.ts#L22-L98

- **S2:** Active credential resolution and the returned model reference, `model-resolver.ts:271-299`; credential replacement/removal, `credential.ts:160-228`; ephemeral switch event, schema `credential.ts:17-29`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/model-resolver.ts#L271-L299

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/credential.ts#L160-L228

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/schema/src/credential.ts#L17-L29

- **S3:** Assistant start records model ref, `runner/publish-llm-event.ts:101-104`; request route/HTTP hooks, `model-request.ts:219-254`; OpenCode workspace comes from Location in `projector.ts:437-453`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/session/runner/publish-llm-event.ts#L95-L112

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/session/model-request.ts#L219-L254

- **S4:** Go/Zen endpoint catalog entries, single-line `snapshot.txt`; endpoint normalization and default prices, `models-dev.ts:82-109,121-155`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/models-dev/snapshot.txt

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/models-dev.ts#L82-L155

- **S5:** First-party Go/Zen service routes, and billing source selection/fallback `handler.ts:833-973`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/console/app/src/routes/zen/go/v1/chat/completions.ts

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/console/app/src/routes/zen/v1/chat/completions.ts

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/console/app/src/routes/zen/util/handler.ts#L833-L973

- **S6:** Token normalization, runtime cost formula and missing prices, `session/usage.ts:8-42`; total definition, `token-usage.ts:16-18`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/session/usage.ts#L8-L42

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/schema/src/token-usage.ts#L16-L18

- **S7:** Remote/configurable provider endpoints and model costs, `plugin/provider/opencode.ts:114-181`; model cost shape, `schema/model.ts:79-91`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/plugin/provider/opencode.ts#L114-L181

- **S8:** ChatGPT workspace header, routing and zeroed price list, `plugin/provider/openai.ts:261-304`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/plugin/provider/openai.ts#L261-L304

- **S9:** Fork zeroed counters and copied message identity/timestamps, `projector.ts:106-225`; current stats fork filter `stats.ts:127-147`. Upstream tests read, not run: `session-stats.test.ts:125-228`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/session/projector.ts#L106-L225

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/test/session-stats.test.ts#L125-L228

- **S10:** Stream failure/final usage, `runner/step.ts:170-240`; session deletion `projector.ts:541-542`, usage additions `589,668-679`, committed revert deletion `721-755`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/session/runner/step.ts#L170-L240

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/session/projector.ts#L541-L755

- **S11:** Optional event payload persistence, `bus.ts:176-203`; replay checks and atomic projections/sequence/event inserts `320-434`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/bus.ts#L176-L203

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/bus.ts#L320-L434

- **S12:** V1 compaction conversion `v1-migration.bun.ts:273-313`; assistant copy and lifetime sum `402-466`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/database/v1-migration.bun.ts#L273-L313

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/database/v1-migration.bun.ts#L402-L466

- **S13:** Import preserves message/session identity and usage, rejects existing sessions; `transfer.ts:64-152`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/session/transfer.ts#L64-L152

- **S14:** Internal overhead event schema `session-event.ts:135-145`; title usage `title.ts:56-92`; compaction usage `compaction.ts:380-389,452-456,521`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/schema/src/session-event.ts#L135-L145

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/session/title.ts#L56-L92

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/session/compaction.ts#L380-L521

- **S15:** Upstream statistics aggregation/model buckets `stats.ts:127-184`; compaction event addition and step-based activity `281-346`; timezone key `398-408`.

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/session/stats.ts#L127-L184

https://github.com/anomalyco/opencode/blob/b2cecc6350d377c382e1ec32ee66ec63ad68f715/packages/core/src/session/stats.ts#L281-L408

## Checks performed

GitHub REST reads, upstream beta fetch/revision comparison, cited source/test reads, installed CLI version, timezone link, read-only SQLite schema/aggregate checks and bundled-catalog lookup all completed successfully. Every immutable source-link path was verified with `git cat-file -e` at its cited revision; the trailing-whitespace check passed. No application code, tracker state, branches or commits changed. No upstream test suite, Tally runtime, browser, DST/restart/cache behavior, provider reconciliation or historical dispatch URLs were tested. The research asset is `docs/research/LOCAL-ACTIVITY.md`; the parent owns its publication and issue resolution.
