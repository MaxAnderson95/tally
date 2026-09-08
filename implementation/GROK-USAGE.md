# Grok billing and optional plan

The resident owner reads `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` and `GET https://cli-chat-proxy.grok.com/v1/settings` as independent jobs. Both use the stored bearer access token, `X-XAI-Token-Auth: xai-grok-cli`, and JSON Accept header. OpenCode owns authentication and refresh.

## Source evidence

On September 7, 2026, OpenUsage upstream was fetched and inspected at `70dea9a8fa21ed205aa9ad625b416a1e7792d5a1`. Its client confirms the endpoints and headers. Its decoder documents the observed proto3 credits response and validates `currentPeriod.type`, start, and end before interpreting omitted `creditUsagePercent` as zero. The dated live response in `docs/RESEARCH.md` independently records that omission. No public first-party Grok CLI protobuf source was located; this private contract rests on those observations and the inspected reference implementation.

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/Providers/Grok/GrokUsageClient.swift

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/Providers/Grok/GrokCreditsConfigDecoder.swift

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/Providers/Grok/GrokUsageMapper.swift

Tally accepts omission-zero only for the percentage in a structurally compatible credits config. Present null, Boolean, string, object, or nonfinite percentages fail. Missing PAYG cap or usage stays unknown. Weekly duration is the difference between the actual period endpoints; other period types produce no weekly window. Reset plus duration retains the actual start for pacing.

The reference establishes a positive explicit `onDemandCap.val` as enabled and explicit zero as disabled. Tally preserves `onDemandUsed.val` and the cap as decimal credit quantities, with `credits` in the existing money denomination and source-unit fields. These are not USD and no cash conversion is established. The shared extra-usage presentation supports Off, bounded remaining-first, used-only when enabled without a compatible positive limit, and unavailable. The verified current Grok cap-based enablement naturally produces Off, bounded, or unavailable; it supplies no separate Boolean that could establish enabled-without-cap. Tally does not invent such a field. Shared presentation tests also exercise used-only and incompatible denominations.

Settings supplies only explicit `subscription_tier_display`. A settings HTTP failure, including 401, affects plan alone because rejection of optional settings access does not establish that billing access failed. Billing 401 retains the shared Account credential-block behavior.

## Verification

`bash scripts/test-swift.sh` passed 32 tests, including three Grok tests and the xAI REST/native-owner parity case. `npm --prefix web test` passed seven tests. Swift and TypeScript read the same normalized PAYG fixture. `bash scripts/build-app.sh` passed TypeScript checking, Vite production bundling, arm64 SwiftUI release compilation, and ad-hoc app signing.

The packaged app's read-only `--collect-once` succeeded for the stored Grok Account on September 7, 2026. Billing reported a 604800-second weekly window ending September 12, 100% remaining, explicit zero PAYG cap and usage, and Off. Settings explicitly reported `X Premium`. These are point-in-time readings.

Headless Chrome's rendered DOM contained all four synthetic PAYG body states: `credits 2374.5 remaining`, Off, `credits 125.5 used`, and Unavailable, with Plan unknown. The browser process timed out after producing its DOM, so clean browser lifecycle and responsive geometry remain unverified. Interactive native popover inspection remains unverified; SwiftUI compiled successfully. No reset credit was consumed.
