# Tally

Tally tracks remaining AI subscription usage across the accounts Max uses in OpenCode.

## Language

**Account**: A provider account configured in OpenCode. OpenCode is the source of truth for its name and visibility in Tally.

**Quota window**: A provider-defined usage allowance over a period, with its own remaining percentage and reset time.

**Shortest window**: The shortest-duration quota window applicable to an account. Its remaining percentage drives the 25%, 10%, and 5% low-quota thresholds; exhaustion of another applicable window also warrants attention.

**Banked reset**: An OpenAI reset credit that can be redeemed to restore eligible usage allowance. Availability and eligibility are distinct.

**Low-quota advisory**: Usage context that encourages the model to wrap up and the user to switch accounts when appropriate. It does not force a stop or automatically switch accounts.
