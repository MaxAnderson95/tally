# Recorded activity pricing

Issue #22 adds the shared owner's API-equivalent estimates to recorded activity. Native, web and REST consume the same derived totals. The valuation basis is current standard synchronous/global reference-token value, including Go's published token reference; it is not a historical tariff, bill, subscription charge, quota debit, savings calculation or bound on actual fees.

## Reviewed bundle

`Sources/TallyCore/Resources/pricing.json` contains revision `2026-09-07-r1`, observed September 7, 2026, with 22 exact provider/model entries and two individually documented aliases. Rates are USD per million tokens. Null component rates are unknown. The resource includes compact source excerpts, source URLs, retrieval dates, the immutable Go source URL, comparison operators, component semantics and review qualifications. Compact excerpts normalize formatting and select relevant columns; they are not full HTTP payloads.

SHA-256 over the complete UTF-8 resource, including evidence and rates:

`1753c13f0c8e53de55320e6318319d7601010468610772197002f0dae2ad70c5`

The primary Anthropic pricing/model/alias pages, OpenAI Standard table and Astra/Sol/Luna model pages, Go reference table and exact endpoint IDs, and xAI Grok 4.5/4.6 model tables were retrieved again before transcription. Go's table was also read at `57ef3828431790c53f8f333c7ffbfe88770a1812` in the local upstream clone. OpenCode's normalization/cost function and Responses usage mapper were read at `b2cecc6350d377c382e1ec32ee66ec63ad68f715`. Those revisions establish the cited source semantics, not the installed binary's exact revision. The research's source index remains in `docs/research/ACTIVITY-PRICING.md`.

Only `anthropic/claude-haiku-4-5` to `claude-haiku-4-5-20251001` and `openai/gpt-5.6` to `gpt-5.6-sol` are admitted aliases. Recorded IDs stay unchanged in breakdowns. Unreviewed historical models, unresolved fast/pro suffixes and Ox Alpha remain unpriced. Go Flash uses the first-party `0.15/0.50/0.03` input/output/read rates, without the catalog's half-rate adjustment or subscription allowance multiplier.

## Calculation and coverage

Each retained request selects its tier before any day/provider/model aggregation. Prompt is noncached input plus cache read plus cache write. Output and reasoning are each charged at the output rate once. OpenAI Astra/Sol/Luna and Go Luna use strict `>272000`; direct xAI uses `>=200000`; Go Grok uses `>200000`. xAI equality follows the specific model table accepted by the spec, rather than the research's earlier conservative conflict proposal.

Anthropic writes use the documented 5-minute lower and 1-hour upper rates. Go DeepSeek Flash/Pro use off-peak lower and peak upper rates, without selecting a server billing instant from the local timestamp. Positive components with no reviewed rate remain excluded; known components retain a subtotal. Rows containing any negative historical component remain entirely unpriced with an explicit invalid-reconstruction reason, even if their signed sum is positive. Their signed quantities remain in recorded tokens, exclusion tokens and unpriced component coverage. This avoids interpreting normalization inconsistencies as billable quantities.

Row coverage partitions into missing usage, unpriced, partially priced, bounded and fully priced. Missing usage has null exclusion token quantities. Known priced/unpriced components partition the retained quantities once, including signed invalid records. A verified all-zero row is scalar zero; an unreviewed all-zero row is unpriced; an empty bucket is empty zero. Exclusions make an aggregate partial if it has any priced rows, otherwise unpriced with null bounds. Partial upper values bound only the same included component subset as the lower value. Recorded cost cannot fill an estimate.

Every successful view has one revision and digest for totals, trend and breakdowns. The app verifies the resource digest before recomputation. Restart restores stale cached views; revision/digest mismatch is visibly stale and preserves the old revision. A successful scan replaces all ranges together. A failed scan or unavailable verified pricing bundle preserves the old view. There is no runtime price feed.

## Updating rates

Use a reviewed app release. Re-read the primary URLs, investigate changed exact IDs/aliases/rates/operators, archive the revised compact excerpts, assign a new revision and observation date, and update the digest pin and numeric fixtures. Never edit the contents of a released revision or treat the observation date as a provider-wide effective date. `scripts/build-app.sh` packages the core resource bundle alongside the app resource bundle.

## Verification on September 7, 2026

- `bash scripts/test-swift.sh --filter activity`: 11 tests passed, including the research fixtures, every reviewed tier at threshold minus one/equality/plus one, per-request tier selection, cache/time bounds, exact aliases, unknown suffixes, partial/missing/zero/signed coverage, and old-cache revision recovery.
- `TALLY_ACTIVITY_LIVE_SOURCE="$HOME/.local/share/opencode/opencode.db" bash scripts/test-swift.sh`: 44 tests passed. The read-only activity scan retained 127,401 assistants, including 1,335 Today records, and derived all three ranges with 30 buckets each. This selected no credentials or conversation content and made no provider requests.
- `npm --prefix web test`: 9 tests passed. Swift and TypeScript decode the same partial/range pricing fixture; the older unpriced fixture remains decodable as cached history.
- `npm --prefix web run build` and `bash scripts/build-app.sh`: passed TypeScript checking, Vite production build and Apple Silicon release compilation. `codesign --verify --deep --strict build/Tally.app` passed; the packaged pricing resource has the reviewed digest above.
- The HTTP fixture compares REST bytes to the native owner's activity group and verifies the Go Grok known subtotal with an excluded positive write component.
- After the final resource-verification guard and installed-app resource lookup edits, `bash scripts/test-swift.sh --filter 'activityPricingRevisionCache|routesEnforcePolicy'` passed 2 tests, `bash scripts/test-swift.sh --filter activityPricing` passed 5 tests, and `bash scripts/build-app.sh` passed again. Installed apps resolve the bundle in `Contents/Resources`; the SwiftPM accessor is used only outside an app bundle.

Plain `swift test` failed to locate the Command Line Tools Testing framework; the documented repository wrapper supplied its framework paths and passed. New native/web pricing layouts were compiled but not visually exercised: the desktop browser was disconnected and Playwright MCP exposed no callable tools. Live bill reconciliation, historical tariff reconstruction and actual provider billing effects remain outside the verified evidence.
