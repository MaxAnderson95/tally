# Anthropic subscription collection

Verified September 7, 2026. `AnthropicUsage` reads stored OpenCode OAuth access tokens without login or refresh. Usage and profile are independent `CollectionJob`s. The owner applies their observations, freshness, cooldowns, persistence, and credential rejection policy; clients read the resulting groups.

## Verified provider interface

- GET `https://api.anthropic.com/api/oauth/usage` uses Bearer authentication, `anthropic-beta: oauth-2025-04-20`, `Accept: application/json`, and `User-Agent: claude-code/2.1.69`. A live GET confirmed the endpoint and the legacy and structured schemas below. Header necessity was not tested by omission.
- GET `https://claude.ai/api/oauth/profile` uses the same headers. A live GET confirmed `organization.organization_type`, `organization.rate_limit_tier`, and account subscription flags. Plan naming uses organization type. A Team organization reported `default_claude_max_5x` while its account's Max flag was false, so rate-limit tier must not name the subscription Max. Missing organization type stays unknown. Unrecognized organization types retain their provider text.
- Each request has a 10-second timeout. HTTP 401 blocks the credential through the owner. Other failures retain last-good values, with Retry-After and normal backoff. Provider bodies and credentials are absent from public errors.

OpenUsage's checked upstream revision corroborates usage headers, legacy mappings, and scoped weekly limits. The bridge source corroborates profile URL and authentication. Anthropic's public Claude Code repository does not contain the private usage implementation; the current provider GET responses are the primary schema evidence.

https://github.com/robinebers/openusage/tree/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/Providers/Claude

https://github.com/dotCipher/opencode-claude-bridge/blob/ed0d49d3712cfc14b3e96fc6a3f949f1e6fea4b2/src/index.ts

The profile source was inspected locally at `~/.btca/agent/sandbox/opencode-claude-bridge/src/index.ts:520-538` and `src/constants.ts:32-34`. The earlier inventory and live-spike evidence is in `docs/research/PROVIDER-DATA-AND-RESETS.md` and `docs/RESEARCH.md`.

## Normalization

Legacy `five_hour` and `seven_day` map to structured `session` and `weekly_all`. Legacy Sonnet/Opus map to the corresponding named weekly scopes. Structured observations replace equivalent legacy observations once, even when their values disagree. Window IDs include provider kind and scope rather than array position, percentage, or reset date. Known session/weekly durations use `verified_mapping`; other interpretable windows retain unknown duration. Provider model IDs remain nullable even when display names identify scope.

Account-wide windows and Fable appear in cards. Other identifiable scopes stay in REST with `displayInOverview: false`. Scoped windows cannot enter pins. Fable's percentage is relative to its own suballowance; details explain that Fable can use up to half of weekly allowance and supplies no additional weekly capacity.

Structured `spend` is authoritative when present. Its `amount_minor`, currency, and exponent produce decimal-string `Money`, preserving the original amount and units. Legacy credit money uses reported currency/decimal places, with the verified historical USD/cents mapping only when those fields are absent. Structured nulls are not filled with older equivalent legacy amounts. Decimal arithmetic derives compatible-currency remaining amounts; no provider-reported percent is substituted for money arithmetic.

Explicit disabled state is Off. Enabled usage with no positive compatible limit is used-only, including measured zero. A positive compatible limit is bounded and remaining-first. Missing enablement or usage is unavailable. Structured spend has no invented monthly period; only the legacy monthly-limit mapping establishes that label.

## Verification

Synthetic fixtures exercise conflicting structured/legacy duplicates, Fable and hidden Sonnet, unknown durations and percentages, metadata absence, Team versus Max tier, exact currency/exponent preference, disabled/unknown/zero/negative-limit/unbounded/bounded money, incompatible currencies, malformed responses, HTTP rejection, Retry-After, and network failure. HTTP tests compare REST bytes to the native owner's snapshot. Swift and TypeScript decode the same exact-money fixture.

The compiled `Tally --collect-once` collector successfully read both stored Anthropic accounts, including Off and used-only spend. Read-only provider requests consumed no reset credits and performed no login/refresh. Headless installed Chrome rendered the four extra-usage states and Fable details at 320, 390, and 1000 CSS pixels without horizontal page overflow. Native SwiftUI compiled; native popover visual inspection and packaged release validation remain for the presentation/packaging layers.
