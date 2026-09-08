# Account identity and preferences

The shared owner reconciles complete subscription inventory before scheduling collection. `OpenCodeInventory.swift` reads only the credential columns it needs; activity tables do not participate in credential compatibility checks. Supported authentication is Anthropic `claude-subscription`, OpenAI `chatgpt-browser`/`chatgpt-headless`, xAI `device`/legacy `browser`, and OpenCode Go keys. Unsupported methods and integrations are excluded before deduplication. OAuth credentials remain included when expired; Tally does not refresh them or infer that expiry requires reauthentication.

`AccountIdentity.swift` keeps per-database namespaces, opaque Account IDs, pins, six-color sequence counters, producing-identity evidence, and current last-good readings. The owner is the only writer. Writes use atomic file replacement with owner-only permissions; failure remains visible in native settings and does not stop collection. Explicit pin changes report failure and roll back in memory when saving fails. The file is best-effort preference/reading recovery, not command recovery storage. An unreadable/damaged file starts new identities conservatively; command recovery must use separate required storage and must not treat missing identity state as permission to consume.

## Continuity rules

- Database identity hashes the filesystem device, file number, and file creation time. Paths, credential row IDs, labels, active selection, and activity schema are not namespace identity. Symlinks/renames recognize the same file; replacement by a different file creates a namespace even with identical rows. A destructive rewrite that preserves all filesystem identity attributes cannot be distinguished from changes to that same database using these attributes alone.
- OpenAI `metadata.accountID` is the verified workspace selector. Equal known selectors prove the same service target even across token refresh. Different selectors remain distinct with a shared token. Known versus missing selector is uncertain and never deduplicates.
- Go key equality proves continuity. Distinct Go keys remain separate. For Anthropic/xAI and OpenAI without a known selector, an unchanged access or refresh token proves continuity. Fully rotated tokens without stable provider evidence create a new Account with no inherited readings or pins. Tally does not infer identity from unverified JWT claims, email, names, or row IDs.
- Proven duplicates choose creation time then credential ID. Initial assignment sorts by provider, lowercased name, original name, then stored credential ID. IDs are random opaque UUIDs persisted with the association. Later display ties use opaque Account ID; pins retain their saved order.
- Successful removal clears readings/pins, retaining identity/color association. A recognized return keeps its ID/color and starts unpinned. Failed inventory reads keep last-known inventory and stale groups. Database switching cancels old collection and prevents its completion from updating the new namespace. Returning restores readings stale.

Anthropic and xAI Accounts therefore do not preserve ID, pins, or readings across a refresh that rotates both tokens, even when OpenCode updates the same credential row. Tally cannot distinguish that rotation from replacement using the retained evidence.

`TallyOwner.identityEvidence(accountID:)` gives later command recovery a Codable, nonsecret target comparison. `same` proves a match across namespaces; `different` requires a different provider or different known OpenAI workspace; `uncertain` must not release an unresolved command block. The command layer must retain original namespace/Account/operation identities and evidence durably, refresh inventory before targeting, and refuse uncertainty until resolved by its command policy. REST never includes this evidence. Reading or acknowledging an old command must not depend on the Account still being in inventory.

The activity layer (#21) must use the owner's current inventory namespace, clear its displayed view on namespace departure, and validate activity-specific schema separately. The provider collectors (#17-19) must keep using selected stored credentials rather than active connections. The presentation layer (#20) consumes persisted `pinned`, `pinOrder`, and `identityColorIndex`; the complete logo/pin renderer and exact visual palette remain in that layer.

## Source evidence

Verified September 7, 2026 against OpenCode V2 `cd9d06c1ca0d5098178c0d4b929aa8a7fde8c69b`: `packages/schema/src/credential.ts`, `packages/core/src/plugin/provider/openai.ts` (workspace extraction and refresh), and `packages/core/src/plugin/provider/xai.ts` (device authentication, browser migration, refresh metadata). xAI stores no stable user identifier in this path. Anthropic's core plugin has no subscription connector; Max's `opencode-claude-auth` revision `faf12ff41fda501001812f5155293716e7b2c946`, `src/oauth.ts`, defines `claude-subscription` and preserves metadata during refresh but adds no stable account identifier. Evidence comes from source inspection, not new live provider calls.

https://github.com/anomalyco/opencode/tree/cd9d06c1ca0d5098178c0d4b929aa8a7fde8c69b/packages/core/src/plugin/provider

https://github.com/MaxAnderson95/opencode-claude-auth/blob/faf12ff41fda501001812f5155293716e7b2c946/src/oauth.ts

## Verification on September 7, 2026

- `bash scripts/test-swift.sh`: 13 tests passed, including all-provider read-only SQLite inventory, same-workspace deduplication, separate workspaces with shared tokens, excluded auth methods/Zen/MCP, compatible additions, independent credential schema validation, failed versus empty inventory, first-batch pinning, duplicate names, provider-local palette wrap, rename/refresh/replacement/removal, restart, namespace switch/return, symlink/rename/replaced files, preference-write failure, in-flight state across inventory rescans, and owner-to-REST pin order. Existing Go and HTTP checks also pass.
- `npm --prefix web test`: two shared-wire/compatibility tests passed. `npm --prefix web run build`: TypeScript and Vite passed.
- `bash scripts/build-app.sh`: passed. `file build/Tally.app/Contents/MacOS/Tally` reported an arm64 Mach-O executable. `codesign --verify --deep --strict build/Tally.app` passed.
- `git diff --check`: passed. Native settings compiled, but interactive pin/path controls and the changed web layout were not visually exercised. No real credential database or provider endpoint was read during this slice, and no reset consume ran.
