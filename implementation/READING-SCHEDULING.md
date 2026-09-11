# Reading scheduling and recovery

`TallyOwner` owns attempt policy. The app calls `tick()` once per second while running and `wake()` on launch and macOS wake. The owner reads inventory every 120 seconds and before explicit requests, starts due collection, and returns cached snapshots without provider reads. An explicit request validates all Account IDs before scheduling, collapses duplicates, and independently requests activity. Empty targets request activity only. A successful inventory replacement is checked again before scheduling the supplied IDs.

## Collection seam

`CollectionJob` describes one endpoint, its stable job ID, the groups it observes, and its async read. One job must report exactly its declared groups, including successful absence. Jobs within an Account must have unique IDs and disjoint groups. Go's usage endpoint observes all six groups together; the unsupported groups are successful absence. Future optional endpoints use separate jobs so their cooldowns and failures cannot stale an independent successful observation. Add concrete `GroupObservation` payload types as provider layers introduce the remaining DTOs.

Each job joins in-flight work, applies a 60-second attempt minimum, and preserves its 2/4/8/15-minute failure count and cooldown deadline in its identity record. Longer Retry-After deadlines win. Explicit refresh and wake can request an early healthy observation but cannot bypass cooldowns. An Account scheduling summary prioritizes started, joined, deferred, then blocked; group state supplies independent deadlines and errors. Attempts record their start time, observations record completion time, and successful absence clears old data.

Credential rejection blocks all jobs using the same access-token fingerprint. Expired OAuth values block before network access, including `expires: 0`; the SQLite parser converts OpenCode's epoch milliseconds to `Date`. A changed usable access token releases that credential block only when the inventory identity still proves continuity. Tally never refreshes credentials. Cancellation plus namespace and fingerprint checks discard completions from replaced credentials or databases.

The private activity seam accepts an async scan and maintains its own attempt state, in-flight joining, and freshness. Every valid explicit refresh requests a scan even during provider cooldown. The production scanner currently reports `not_implemented`, leaving its observation time unavailable; the activity layer connects the real scan and its payload/cache. This schedule does not fabricate successful activity times.

## Recovery and derived values

`AccountIdentityStore` retains one identity-associated last-good value per group and job scheduling state, with no raw credentials. Restored readings are stale; refreshing does not survive restart. A malformed cache starts with empty recovery state, and an unwritable cache reports a settings-storage error while collection continues. Best-effort reading storage does not provide command recovery guarantees. Successful Account removal clears readings and attempt policies; recognized database returns restore their associated readings as stale.

Cached reads age groups at five minutes and quota windows at reset passage. They retain observed percentages and reset instants. Pacing requires fresh positive usage, a known positive duration, a future reset, and elapsed time within the window and at least the larger of 60 seconds or 1% of duration. Derived projections keep negative spare allowance and over-100 usage; unavailable reasons distinguish timing, usage, freshness, and numeric failures. Go Monthly has no assumed duration.

Native details and browser details expose attempt, observation, next-attempt, refreshing, stale, and error state. Both show refresh scheduling results separately from successful observation time. Browsers age cached readings between polls and preserve values on transport failure.

## Source evidence

Rechecked the local OpenCode beta checkout on September 7, 2026 at `cd9d06c1ca0d5098178c0d4b929aa8a7fde8c69b`. `packages/core/src/plugin/provider/openai.ts` constructs OAuth expiry with `Date.now() + expires_in * 1000`; the xAI provider uses the same millisecond convention. Go mappings and absence semantics use the source verification recorded in [Go runtime](GO-RUNTIME.md). No provider consume request is involved in these checks.

https://github.com/anomalyco/opencode/blob/cd9d06c1ca0d5098178c0d4b929aa8a7fde8c69b/packages/core/src/plugin/provider/openai.ts

## Verification on September 7, 2026

- `bash scripts/test-swift.sh`: 20 tests passed, including controlled-clock cadence/wake, minimum/joining, backoff/Retry-After across restart, credential expiry/rejection/rotation, independent groups and Accounts, separate activity failure/recovery, corrupt/unwritable storage, reset passage, pacing boundaries, and HTTP routing. The five scheduling tests passed again after removing a redundant policy check.
- `npm --prefix web test`: four tests passed. Swift and TypeScript decode the same Accounts and Refresh fixtures, including nullable fields, measured zero, successful absence, stale failure, and all four scheduling states.
- `npm --prefix web run build` and `bash scripts/build-app.sh`: passed. The executable is arm64 Mach-O; `codesign --verify --deep --strict build/Tally.app` passed.
- Headless installed Chrome against the built web assets and synthetic fixture HTTP responses at 390px displayed the four scheduling states, stale data, attempt/observation/deadline details, and unknown versus measured-zero quotas, with no horizontal overflow. The screenshot was inspected.

The controlled-clock tests exercise the owner's wake entry point; actual macOS sleep/wake and native visual interaction were not exercised in this layer. No live provider request or credit redemption ran. The activity scanner and non-Go collectors remain the later layers' work.
