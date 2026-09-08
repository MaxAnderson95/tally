# OpenAI usage and read-only reset credits

Verified September 7, 2026. The resident owner collects WHAM usage and the dedicated reset-credit list as separate jobs, using each stored OpenCode credential and its explicit `ChatGPT-Account-Id`. Missing workspace metadata prevents requests. Tally does not refresh tokens or send credit-consumption requests.

## Source evidence

Codex upstream `main` was fetched and inspected at `98a5cb46b110dcf813b45373f46a2763c4711436`. Its backend client confirms GET `/backend-api/wham/usage`, GET `/backend-api/wham/rate-limit-reset-credits`, actual `limit_window_seconds`, primary/secondary windows, additional limits, purchased balance strings, and credit identity/type/status/grant/nullable expiry. Its picker accepts explicit available status. The current app-server status model also recognizes redeeming and redeemed.

https://github.com/openai/codex/blob/98a5cb46b110dcf813b45373f46a2763c4711436/codex-rs/backend-client/src/client/rate_limit_resets.rs

https://github.com/openai/codex/blob/98a5cb46b110dcf813b45373f46a2763c4711436/codex-rs/backend-client/src/types.rs

https://github.com/openai/codex/tree/98a5cb46b110dcf813b45373f46a2763c4711436/codex-rs/codex-backend-openapi-models/src/models

https://github.com/openai/codex/blob/98a5cb46b110dcf813b45373f46a2763c4711436/codex-rs/app-server-protocol/src/protocol/v2/account.rs

OpenUsage upstream was fetched and remained at `70dea9a8fa21ed205aa9ad625b416a1e7792d5a1`. Its mapper establishes the comparison rate of USD 0.04 per purchased credit and the Pro/Business display names. This rate is reference-derived; the WHAM balance is a credit quantity, not provider cash. Tally preserves fractional quantities and unknown/unlimited states.

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/Providers/Codex/CodexUsageMapper.swift

## Observation selection

Usage owns plan, quotas, balances, successful extra-usage absence, and its embedded reset summary. The credit-list job owns reset details. `ResetDetails.summary` is an additive DTO field retaining the dedicated counts with their producing list observation; it is also persisted with that group. Each job keeps independent attempt policy and freshness.

The cached usage summary remains intact. On snapshot, the owner prefers fresh dedicated details, otherwise the newer successful observation. It copies the entire selected group's source, counts, observation time, attempt, scheduling, error, and stale state. It never fills missing dedicated applicability from a usage observation. A newer embedded summary remains usable when the list fails. Successful null/empty observations replace prior values.

Additional quota windows remain in REST and are hidden in native/web overview rows. Window IDs use provider meter identity and primary/secondary slot; durations come from the provider. Relative resets anchor once at collection. Missing or invalid duration stays unknown. Credit expiry distinguishes a decoded date, explicit schema null (nonexpiring), and missing/unreadable data (unknown). Unknown status never becomes available.

## Verification

The packaged arm64 app's read-only `--collect-once` successfully collected both stored OpenAI workspaces. Personal reported Plus, five-hour and weekly quota, supplementary reserve quota, zero purchased credits, and three reset credits. Work reported Business Premium, one weekly quota, unknown purchased quantity, and two reset credits. Dedicated lists did not report applicability. These are point-in-time observations, not persistent account guarantees.

Swift fixtures cover actual/unknown durations, weekly-only overview, hidden model scopes, purchased-credit provenance, zero/null counts, source preference, independent detail failure, all expiry states, malformed values, missing workspace rejection, and same-token workspace isolation. REST bytes are compared to the native owner's snapshot. Swift and TypeScript decode the same normalized credit and balance fixture.

Installed headless Chrome rendered account-scoped credit details at 320, 390, and 1000 CSS pixels with no horizontal page overflow. It showed dated, nonexpiring, and unknown expiry, nullable availability/applicability, stale group errors, and only the Refresh button. SwiftUI compiled in the arm64 app; interactive native popover inspection remains unverified. No reset credit was consumed.
