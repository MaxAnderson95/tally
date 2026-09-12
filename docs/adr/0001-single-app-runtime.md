# One app owns Tally's runtime

Tally's resident Swift macOS app owns collection, cached readings, banked-reset redemption, and HTTP so native and remote clients share one state and command owner. The native menu bar calls that owner's Swift interface; Hummingbird serves the REST interface and bundled React/TypeScript/Vite assets to browser and companion clients. This avoids separate collector lifetimes and cross-process cache synchronization, at the accepted cost that quitting, crashing, or updating the app interrupts all Tally surfaces.

Tally reads one local OpenCode V2 credential database so collection can continue while OpenCode is stopped and stored credentials remain usable. OpenCode owns account names and sign-in. Auto warm-up and its model picker refresh near-expiry OAuth credentials directly and persist replacement tokens to the selected row, preserving its metadata and active-account selection. This allows unattended warm-up without a running OpenCode process or refresh plugin. Refresh failures reread the row and allow one retry; a conditional write avoids overwriting an intervening credential change. Concurrent provider refresh races remain an accepted limitation. Tally accepts private-schema coupling rather than requiring a live plugin collector. Incompatible schema changes stop credential access and leave last-known readings explicitly stale until compatibility is restored.

The canonical resolution, lifecycle and distribution choices, source evidence, and follow-up scope are recorded in **Define Tally's single-app architecture, credential access, and lifecycle**:

https://github.com/MaxAnderson95/tally/issues/5
