# One app owns Tally's runtime

Tally's resident Swift macOS app owns collection, cached readings, banked-reset redemption, and HTTP so native and remote clients share one state and command owner. The native menu bar calls that owner's Swift interface; Hummingbird serves the REST interface and bundled React/TypeScript/Vite assets to browser and companion clients. This avoids separate collector lifetimes and cross-process cache synchronization, at the accepted cost that quitting, crashing, or updating the app interrupts all Tally surfaces.

Tally reads one local OpenCode V2 credential database read-only so collection can continue while OpenCode is stopped and stored credentials remain usable. OpenCode and its auth plugins own account names, sign-in, and token refresh. Warm-up reads the selected Account's current access token and makes one message request; model discovery is a separate read-only operation for Settings. Tally never calls OAuth refresh endpoints or writes to OpenCode's database. Expired or rejected credentials depend on OpenCode to supply a usable token. Tally accepts private-schema coupling rather than requiring a live plugin collector. Incompatible schema changes stop credential reads and leave last-known readings explicitly stale until compatibility is restored.

Account selection is the one OpenCode mutation exposed by Tally. All three surfaces call the owner, which asks the local OpenCode service to activate a stored credential, then rereads the database to confirm selection. OpenCode owns the write and its `credential.switched` event; direct SQL would skip provider-state reloads. Collection remains independent of the service. Switching discovers the standard local service registration, checks the configured database identity and stored connection, and requires a running service. It does not start or restart OpenCode. Failed or lost responses are not automatically retried.

Source for activation and provider reload behavior:

https://github.com/anomalyco/opencode/blob/beta/packages/core/src/credential.ts

https://github.com/anomalyco/opencode/blob/beta/packages/core/src/plugin/provider/openai.ts

The canonical resolution, lifecycle and distribution choices, source evidence, and follow-up scope are recorded in **Define Tally's single-app architecture, credential access, and lifecycle**:

https://github.com/MaxAnderson95/tally/issues/5
