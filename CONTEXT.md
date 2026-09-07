# Tally

Tally tracks remaining AI subscription usage across the accounts Max uses in OpenCode.

## Language

**Account**: A supported provider subscription account stored in OpenCode. Tally includes active and inactive stored accounts and uses their OpenCode names. Environment-only credentials are outside this inventory.

**OpenCode Go**: OpenCode's subscription service with 5-hour, weekly, and monthly quota windows. Go accounts are distinct even when they use the same service; sharing a key with Zen does not make Zen usage Go usage.

**OpenCode Zen**: OpenCode's per-token service billed against a prepaid balance. Zen is outside Tally v1's scope, even when a Zen entry shares an API key with a Go entry.

**Quota window**: A provider-defined usage allowance over a period, with its own remaining percentage and reset time.

**Shortest window**: The shortest-duration quota window applicable to an account.

**Local activity**: Token usage and recorded or estimated costs from this Mac's OpenCode activity records. Local activity is distinct from provider-reported subscription quota consumption and is account-attributed only where the records establish that association.

**Banked reset**: An OpenAI reset credit that can be redeemed to restore eligible usage allowance. Availability and eligibility are distinct.

**Pin**: A pinned Account's menu bar item: the provider logo in the Account's identity color with its remaining percentages. Pinning controls menu bar visibility only, not collection or inclusion.

**Identity color**: The color that distinguishes an Account from other Accounts of the same provider, assigned in order from a fixed six-color palette whose first color is monochrome. It never carries status meaning.
_Avoid_: status color, account color
