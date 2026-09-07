# Go runtime source contract

## Ownership and extension points

`TallyCore/TallyOwner.swift` is the actor that owns inventory, in-memory last-good readings, explicit refresh scheduling, and clock-derived views. `snapshot()` and `account(id:)` are cached reads; `refresh(accountIDs:)` returns scheduling results without waiting for provider requests. Native SwiftUI reads this actor directly. `TallyHTTP` handles HTTP policy, route dispatch, and immutable bundled assets. `TallyApp` owns the HTTP and collection task lifetimes independently of the popover. Tests substitute the inventory and collection functions at the owner's internal seam.

`Models.swift` defines the v1 DTO subset needed for Go. Its `Null` property wrapper encodes required unavailable fields as JSON null. Go's unused data groups use `AbsentData`, always null, until later provider layers supply concrete DTOs. `web/src/api.ts` holds the matching handwritten TypeScript shapes. Clients format percentages and countdowns; the owner derives remaining percentages, staleness, pin lines, and pacing.

`AccountIdentity.swift` stores namespace-aware identity, preferences, provider-local palette sequencing, and last-good readings. See [Account identity](ACCOUNT-IDENTITY.md) for continuity evidence and storage behavior. Later scheduling work adds backoff, Retry-After, rejected-credential blocking, and persistent cooldowns. Login startup, complete native/web presentation, and release distribution remain their own tickets. The installed slice has no helper or redemption implementation.

## Verified upstream revisions

Inspected September 7, 2026 after updating the local BTCA checkouts:

- OpenCode V2 beta: `cd9d06c1ca0d5098178c0d4b929aa8a7fde8c69b`. Credential table: `packages/core/src/credential/sql.ts`; value shape: `packages/schema/src/credential.ts`; data roots: `packages/util/src/global-roots.ts`; filename/channel selection: `packages/cli/src/server-process.ts`; relative database resolution: `packages/core/src/database/database.ts`.
- OpenCode dev (Go server): `ecbc6ccac85b3e8087b6445e584318419b9e2b34`. `packages/console/app/src/routes/zen/go/v1/usage.ts` verifies Bearer key authentication, successful entitlement, rolling/weekly/monthly response fields, and 401/403 failures. `packages/console/core/src/subscription.ts` defines the calendar weekly/monthly calculations; `packages/console/app/src/i18n/en.ts` documents the Go five-hour window. The endpoint's configured rolling duration is not included in the response, so five-hour duration is marked `verified_mapping`, not `provider`.
- Hummingbird: `80b4445a88503fc6c8062ec40631eb7f9d93b837`. `Application.run()` owns a ServiceGroup; cancellation ends that lifetime. `HTTPResponder`, `Request.head.authority`, bounded body collection, and the testing interface were checked directly against this source.

https://github.com/anomalyco/opencode/tree/cd9d06c1ca0d5098178c0d4b929aa8a7fde8c69b/packages/core/src

https://github.com/anomalyco/opencode/blob/ecbc6ccac85b3e8087b6445e584318419b9e2b34/packages/console/app/src/routes/zen/go/v1/usage.ts

https://github.com/hummingbird-project/hummingbird/tree/80b4445a88503fc6c8062ec40631eb7f9d93b837

The current Go server always emits `resetsAt`, including zero-usage rolling windows. A missing reset therefore remains unknown; this revision establishes no absent-reset Not started mapping. Monthly has no assumed duration. Explicit zero remains measured zero; absent percentages remain null. Unknown/absent meter groups do not become synthetic zero-usage windows. Malformed present percentages or reset instants fail the observation and preserve the last-good reading.

`Package.resolved` pins the complete Swift dependency graph. The web package/lockfile pin React 19.2.4, TypeScript 5.9.3, Vite 7.3.6, and their dependencies. Production web assets use Vite's root base and no history fallback. Package builds are ad-hoc signed for local Apple Silicon execution, without Developer ID or notarization.

## Verification on September 7, 2026

Environment: macOS 26.6.2 (25G83), arm64, Apple Swift 6.3.2, Node 22.22.2, installed `opencode2 v0.0.0-beta-19242`. The inspected upstream revision is source evidence, not a claim that the installed binary was built from that exact commit.

- `bash scripts/test-swift.sh`: seven tests passed. These cover read-only SQLite inventory, active/inactive Go inclusion, Zen exclusion, distinct keys, deterministic duplicate choice, zero/absence/malformed usage, millisecond reset round-trip, shared JSON fixture decoding, cached reads, stale last-good after failure, reset passage, HTTP policy/routing, real listener collision, cancellation, and a fresh listener binding the released port.
- `npm --prefix web test`: two Node tests passed, decoding the same Accounts fixture in TypeScript and checking unavailable/zero/reset/version behavior.
- `npm --prefix web run build` and `bash scripts/build-app.sh`: passed. `file build/Tally.app/Contents/MacOS/Tally` identified an arm64 Mach-O executable; `codesign --verify --deep --strict build/Tally.app` passed.
- Live `--collect-once` and packaged app launch both read two stored Go Accounts successfully. Each had rolling, weekly, and Monthly meters, with Monthly duration null. The checks printed only public normalized fields, without credentials, raw database rows, or raw provider payloads. No credit redemption ran.
- Packaged loopback HTTP checks passed: Account list/detail parity, unchanged observation timestamps across GETs, real bundled JS/CSS requests, API and missing-asset JSON 404s, refresh GET 405, non-JSON POST 415, and hostile Host/Origin 403s.
- Installed Chrome rendered the packaged web app at 320, 390, and 1100 CSS pixels. All widths had zero horizontal overflow, two live cards, six 4px bars, and Monthly duration-unknown labels. Light/dark screenshots were inspected. Simulated offline transport retained both cards and displayed an explicit stale connection error.
- A normal application Quit returned and the loopback listener stopped accepting connections. The native popover compiled and the resident app launched; automated opening/visual inspection was blocked by macOS denying osascript assistive access. Native visual interaction, actual wake, and Tailscale proxy exposure remain unverified. Download/quarantine and login startup belong to the later packaging layer.
