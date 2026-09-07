# Recorded activity verification

Issue #21 implements specification sections 7, 9 (Activity DTOs), and 11 on the cards-and-pins layer. Pricing is deliberately `unpriced-1`; #22 supplies reviewed rates. Empty buckets have zero token sums and an empty estimate, missing usage has null token quantities, and a nonempty unpriced estimate has null bounds even when recorded tokens or cost are zero.

## Source mapping

Fetched `anomalyco/opencode` beta on September 7, 2026 and inspected revision `013ded3743eb9c198d8f544afdfd60fdad1e68a4` directly through the local BTCA clone. No checkout/reset of the shared clone was required.

- `packages/schema/src/session-message.ts` retains assistant model reference, optional tokens/cost, and creation time. Tally selects only those structural/numeric fields, not conversation content or credentials.
- `packages/schema/src/token-usage.ts` defines five finite components and their sum. `packages/core/src/session/usage.ts` currently normalizes omitted/negative inputs to zero and computes runtime-price cost. `packages/schema/src/money.ts` accepts finite USD values. Historical projections can contain signed values; Tally preserves them with a visible qualification.
- `packages/core/src/session/projector.ts` copies fork prefixes with original timestamps and sequence numbers and records the parent/before-or-after boundary. Tally excludes timestamps before fork creation, even when ancestors were deleted, and uses a surviving boundary's sequence to exclude same-millisecond prefixes. Child sessions are included. Tally does not fingerprint requests, add V1 remnants, replay events, or add lifetime session totals.
- `packages/core/src/session/stats.ts` confirms the timestamp-based fork exclusion, but its step trend and separate compaction-event addition are not Tally's token contract.

https://github.com/anomalyco/opencode/tree/013ded3743eb9c198d8f544afdfd60fdad1e68a4/packages/core/src/session

https://github.com/anomalyco/opencode/blob/013ded3743eb9c198d8f544afdfd60fdad1e68a4/packages/schema/src/token-usage.ts

The read-only live-source check initially exposed 22 historical Go records with negative visible output, down to -183. Rejecting negative components would have rejected otherwise compatible history; the scanner now accepts the source's finite-value contract. A subsequent successful scan read 127,313 retained supported-provider assistants, 1,247 in Today, and derived 30 buckets for every range. These counts are a changing observation, not a completeness claim. The scan selected no credentials, account names, conversation text, tool output, or provider-state values.

## Ownership and recovery

`TallyOwner` captures cutoff and timezone, runs the read-only scan and derivation off its actor, and publishes all three ranges together. GETs do not scan. Activity scheduling has its own two-minute deadline, in-flight joining, immediate failure staleness, and five-minute aging. Explicit refresh and wake bypass activity cadence, independently of provider cooldown. Credential-schema failure does not block a compatible activity read.

The best-effort namespace cache in `accounts.json` retains the three derived groups with source/schema identity, original calendar intervals/timezone, observation timestamps, coverage, and pricing revision/digest. Restoration is stale. A successful rescan replaces those views rather than incrementing totals; removing an Account cannot remove provider history. A timezone change or new local day makes the old view explicitly stale until scanning succeeds, without relabeling its buckets.

## Evidence boundary

- `TALLY_PRESENTATION_OUTPUT="$PWD/build/activity" TALLY_ACTIVITY_LIVE_SOURCE="$HOME/.local/share/opencode/opencode.db" bash scripts/test-swift.sh`: 39 tests passed, including native rendering and the live read-only activity scan. That final full-suite observation had 127,329 retained assistants and 1,263 in Today.
- `bash scripts/test-swift.sh --filter activityScannerRetainsRequestsExcludesForksAndReplacesMutableSource`: passed after changing recorded-cost extraction to preserve the JSON number's decimal text rather than SQLite's rounded numeric cast; the regression uses `0.123456789123456789`.
- `npm --prefix web test`: 8 tests passed. `npm --prefix web run build`: TypeScript and Vite passed.
- `bash scripts/build-app.sh`: release build and bundle passed. `file build/Tally.app/Contents/MacOS/Tally` identified arm64; `codesign --verify --deep --strict build/Tally.app` passed.
- Reviewed the complete staged implementation diff against the accepted specification and repository standards. `git diff --cached --check` passed. No independent reviewer was dispatched from this child session.

Synthetic tests cover normal and same-millisecond copied forks, deleted ancestors, nested forks, real child requests, identical independent requests, Go/Zen filtering, missing/zero/signed usage, mutable projections, deletion, unreadable/incompatible source, credential-schema independence, Account removal, namespace restoration, timezone recovery, 23/25-hour DST days, cutoff exclusion, range selection, and 30-bucket context. Swift and TypeScript decode the shared `activity.json` fixture. REST tests compare the returned activity group byte-for-byte with the native owner's group and exercise default/valid/invalid ranges and method handling.

Browser evidence uses the built SPA, Chrome 152.0.7977.76, an already-installed external Playwright runner, and a synthetic local HTTP server. At 320, 390, 1000, and 1440 CSS pixels in light/dark appearance, the activity section has 30 bars, selected-range highlighting, wrapping details without horizontal overflow, and sticky positioning only at desktop widths. A failed activity request retains the previous view with an explicit stale connection error. Screenshots are under `build/activity/web-*.png`. The fixture server changes range selection for UI checks; Swift tests verify the actual range totals.

Native captures use the real `RecordedActivity` SwiftUI view at 360px in light/dark appearance, under `build/activity/native-activity-*.png`. This is rendered-view evidence, not a physical menu-bar interaction or iPhone Safari test. No provider collection or credit redemption was needed for activity verification. The source does not prove complete history, historical Account ownership, physical execution location, Go quota billing, or recorded-zero pricing provenance.
