# App architecture, packaging, and lifecycle

Research for "Study app architecture, packaging, and lifecycle in OpenUsage and openusage-web", 2026-09-06. This report records source inspection and design questions; it does not select Tally's architecture.

https://github.com/MaxAnderson95/tally/issues/2

## Findings that affect the decision

- **Swift already hosts the reference API.** OpenUsage's menu-bar process owns native UI, collection, cached state, notifications, and an HTTP listener implemented with Apple's Network framework. Go is used by the separate mobile dashboard, not required by OpenUsage to serve HTTP. [S1–S4]
- **Process lifetime is the first decision, language is a separate decision.** Quitting OpenUsage removes its collection loop and HTTP API. Keeping openusage-web running preserves the dashboard server, but does not preserve its upstream API. The bundled Swift CLI can collect without the menu-bar process, but exits after one read. [S2–S5, W1]
- **The current split has two state owners during forced refresh.** The CLI writes a shared persisted cache while the running app serves its own in-memory snapshots. Max's uncommitted web changes restart the app after CLI refresh so it loads that cache. This is evidence for sending refresh commands to one authoritative runtime in Tally, whichever language owns it. [S2, S5–S6, W1–W3]
- **A split need not mean separate downloads.** OpenUsage already distributes its app and CLI in one signed app bundle. A background helper and embedded web assets could likewise share a Tally release, although helper startup, shutdown, and version coordination would still require explicit design. [S10; recommendation]
- **The required OpenCode companion makes the system multi-process under every option.** Tally needs query/redemption tools, TUI threshold notices, and context injection inside OpenCode. Swift-centric therefore describes the macOS runtime, not an attempt to move OpenCode integration into Swift. The direct-DB versus plugin-mediated collection decision is outside this report.

## Evidence scope and reproducibility

OpenUsage was inspected read-only at `/Users/max/.btca/agent/sandbox/openusage`, clean revision `70dea9a8fa21ed205aa9ad625b416a1e7792d5a1`. All S citations below pin that exact commit. Its `AGENTS.md:11–28` identifies this as the active native Swift edition; this report does not describe the legacy Tauri branch.

openusage-web was inspected read-only at `/Users/max/Projects_personal/openusage-web`, base revision `58ff486a3375ec0599d9c5d60e82be575ed0cc20`, plus existing modified `README.md`, `main.go`, `static/index.html`, and untracked `main_test.go`. W citations explicitly distinguish this local state from committed sources. Shared clones were not updated or checked out. No provider credentials, live usage payloads, or account identifiers were read for this investigation.

Tally's `AGENTS.md`, `docs/agents/domain.md`, `CONTEXT.md`, `docs/RESEARCH.md`, and the app architecture research ticket were read. No ADRs were present under `docs/adr/`. The existing viability spike is context, not new endpoint verification: its conclusion that an external tracker need not be a plugin does not decide the now-required OpenCode companion or the separate collection research question.

## OpenUsage: one resident Swift app and one one-shot Swift CLI

### Languages and ownership

`Package.swift` declares Swift tools 6.2, Swift 6 language mode, macOS 15 minimum, a shared `OpenUsage` target, and two executable products: `OpenUsage` and `openusage-cli`. Dependencies include KeyboardShortcuts, Sparkle, and PostHog. SwiftPM copies provider icons and pricing JSON resources into the package resources. [S1]

```text
OpenUsage.app process
  AppDelegate
    AppContainer
      provider runtimes -> WidgetDataStore -> persisted snapshot cache
                              |-> native menu-bar UI
                              |-> notification evaluation
                              `-> loopback HTTP API :6736
    StatusItemController: AppKit status item + panel hosting SwiftUI
    UpdaterController: Sparkle

openusage CLI process, only while invoked
  UsageReader -> same provider implementations and settings/cache domain
              -> JSON stdout, then exit
```

`AppDelegate` constructs the container, status-item controller, and updater. `StatusItemController` constructs an `NSStatusItem`, `NSHostingController` with `DashboardView`, and a custom `NSPanel`. Closing the panel is distinct from quitting the application; collection belongs to the container, not to panel visibility. [S2–S3]

The provider interface contains provider metadata, widget descriptors, `refresh()`, and a local credential probe. Providers normalize results into snapshots. `WidgetDataStore.refreshAll` starts a task per enabled provider and awaits the batch; network awaits overlap while the store remains MainActor-isolated. Blocking credential reads have an explicit detached-task helper. This demonstrates asynchronous collection in Swift, while also showing why blocking I/O must stay off the UI actor. [S7]

The periodic task refreshes on startup and then waits five minutes after each completed pass. Provider-enablement changes can wake it early. The store gates successful reads through the cache, suppresses duplicate in-flight work within that store, uses a 60-second failure backoff, and has a 120-second provider deadline. These are source mechanisms, not measured guarantees about latency or cancellation of every underlying operation. [S2, S7]

### HTTP and commands

The Swift `LocalUsageServer` binds `NWListener` to `127.0.0.1:6736`. It implements a small HTTP/1.1 transport, limits active requests to 16, reads a bounded request head, and calls a pure router against a snapshot of the app's live state. The router supports GET `/v1/usage`, `/v1/usage/:token`, `/v1/limits`, and `/v1/limits/:token`, plus OPTIONS. It has no refresh or redemption route. Listener failures are logged and leave the app running without the API; the inspected code has no listener retry loop. [S4]

This is direct evidence that Swift can host Tally's API. It is not evidence that this particular handwritten HTTP parser should be copied for Tally's required write operations. Server implementation choice and process placement remain independent.

The bundled CLI opens the app's UserDefaults suite and calls `UsageReader`. It can reuse a timestamp-fresh persisted snapshot or instantiate the refresh engine itself, and `--force` bypasses freshness. It has no resident timer, HTTP server, status item, or updater. It emits JSON and exits; provider warnings produce exit code 4 even when JSON was produced. [S5]

OpenUsage's banked-reset write is an in-process UI path: `AppContainer` constructs `CodexResetClaimService` with the existing provider's auth store/client and a post-claim refresh closure. That closure accounts for an already-running pre-claim fetch by retrying a refresh. It is useful evidence for command/read reconciliation, not a Tally auth design to copy: OpenCode owns Tally's accounts, authentication, and refresh. [S2:141–179]

### Persistence and restart loss

| State | Source behavior | Restart consequence |
|---|---|---|
| Last-good provider snapshots | JSON payload in UserDefaults under `openusage.providerSnapshots.v9`; in-memory mirror decodes once per cache instance; error snapshots are not persisted. | Last-good values can display immediately, but the app deliberately treats launch-loaded snapshots as stale and refreshes. [S6] |
| Account attribution of cached snapshots | Sidecar producing-identity map; launch filters entries whose known current identity does not match. Current implementation's account-aware handling is scoped, not a general Tally multi-account model. | Avoids painting a provably wrong account's cached data; unresolved identity remains a distinct case. [S6, S7:169–188] |
| Layout and settings | App constructs persistent layout/settings stores; CLI reads the same app defaults and saved provider order. | Settings survive a normal restart; startup runs versioned settings migration. [S2–S3, S5] |
| Refresh errors, in-flight ownership, failure backoff, last full-pass completion | Dictionaries/sets/timestamp on `WidgetDataStore`, initialized in memory. | Lost at restart; last-good usage may remain while the previous error/backoff does not. [S7:71–103] |
| Notification deduplication | `QuotaNotificationEvaluator.notificationState` is an in-memory dictionary, committed after successful delivery. | Prior notification transition/delivery memory is lost. This does not alone prove a duplicate banner, because transition logic also controls initial evaluation. [S8] |

The cache is a last-good snapshot cache, not a durable log of all quota samples or commands. Snapshots can contain normalized daily usage history; the store also has optional iCloud history aggregation. Those features do not establish durable banked-reset outcomes or durable low-quota advisory deduplication for Tally. [S6, S7:354–454]

The key coherence issue is visible without a live test: `LocalUsageServer` reads `dataStore.snapshots`, and `ProviderSnapshotCache` memoizes its payload per instance. A CLI write to UserDefaults is not a command to mutate the app's in-memory store. The inspected path has no cross-process refresh notification. An app restart reloads disk and starts another collection pass. [S2:215–225, S5–S7]

### Installation, startup, shutdown, and updates

- **Release package:** `script/release.sh` builds arm64 and x86_64 app and CLI products, places them in `Contents/MacOS/OpenUsage` and `Contents/Helpers/openusage`, copies resource bundles, embeds Sparkle, signs the nested executable and app, notarizes/staples the app, and creates/signs/notarizes a DMG containing the app and an Applications symlink. The current release additionally includes iCloud provisioning. These are upstream shipping choices, not all required for a personal Tally build. [S10]
- **CLI installation:** the app can create `/usr/local/bin/openusage` as a symlink into the bundled helper, using macOS authorization. The destination path remains stable across in-place app updates. Moving/deleting the app therefore matters to that installed link. [S11]
- **Login startup:** the toggle registers/unregisters `SMAppService.mainApp`. Startup disables AppKit's separate reopen-at-login behavior, removes a verified legacy autostart entry, and acquires a single-instance lock with a workspace fallback. This shows login startup and duplicate prevention; it does not show a separately supervised collector. [S3, S9]
- **Quit:** the menu calls `NSApplication.shared.terminate`; the delegate flushes telemetry on termination, and the container cancels its tasks on deinitialization. The HTTP listener and polling loop are in that application process, so they cannot remain available after it exits. No claim is made that all pending persistence or provider work is synchronously drained before process termination. [S2–S3]
- **Updates:** `UpdaterController` starts Sparkle only when the packaged bundle has `SUFeedURL`. Release metadata enables automatic checks with a 3600-second scheduled interval. The workflow publishes the DMG to GitHub Releases and a signed Sparkle appcast to GitHub Pages, with stable/beta channels. App and CLI ship together; the separately installed openusage-web binary is outside that update unit. [S10, S12]

## openusage-web: a separately supervised proxy and embedded dashboard

### Runtime and assets

The module targets Go 1.25 and declares no third-party dependencies. `main.go` embeds `all:static`, serves those files with Go's HTTP file server, proxies GET `/api/usage` to OpenUsage's `/v1/usage`, and runs an HTTP server on loopback port 6737 by default. The Go process does not own scheduled provider collection. Its five-second HTTP client timeout bounds ordinary upstream proxy requests. [W1, W4]

The browser runs inline JavaScript and CSS from `static/index.html`; a web app manifest and icons provide standalone installation metadata. The browser's 60-second freshness rule triggers cache reads while visible, with a 15-second timer checking whether a read is due and another timer updating countdowns. Usage is held in a JavaScript object. No service-worker, localStorage, or sessionStorage usage was found in the inspected static tree, so this source does not implement an offline persisted usage cache. A failed fetch keeps existing in-page data and shows an error banner. [W2, W4]

HTML and API responses are marked `no-store`. API responses include an `X-App-Version` generated from server boot time; the browser reloads when that value changes. This coordinates an already-open dashboard with a server restart, but the value identifies a boot, not a source/build revision. Static assets are embedded at Go build time, so changing files on disk does not update a running binary. [W1:22–50, W1:63–68, W2:407–423]

### Existing local modifications

At the committed base, POST `/api/refresh` ran `openusage --force` with a 90-second timeout. The current local implementation adds an app-path flag, raises the total timeout to 120 seconds, then restarts OpenUsage after a successful CLI exit. It sends a normal process termination, waits up to five seconds, escalates to a forced kill if necessary, launches the app with `open -a`, and waits up to 15 seconds for GET `/v1/usage` to return HTTP 200. README and dialog text disclose that restart. [W1–W3]

The endpoint requires a custom request header and permits one forced refresh at a time through an atomic flag. That guard only coordinates requests in this Go process; it does not coordinate with the menu-bar app's collection loop or another CLI invocation. HTTP 200 on the readiness probe proves the listener responded, not that every provider finished its new startup refresh. A nonzero CLI exit, including provider warnings, skips the restart. [W1:70–101, W1:113–167, S5]

The untracked tests cover restart-after-success, no restart after CLI failure, and propagation of restart errors using injected callbacks and `/usr/bin/true` or `/usr/bin/false`. They do not exercise the actual app restart, cache coherence, readiness, or tailnet path. These tests were inspected, not run. [W3]

**Design implication:** the local change addresses a real ownership mismatch in the reference arrangement. Tally should not inherit a web refresh command that launches another collector and then kills the UI process to synchronize state. A single collection/command owner can serve native UI, web, and OpenCode consumers regardless of whether that owner is Swift, Go, or another runtime. This is a recommendation, not a selected process topology.

### Supervision and update ownership

The repository's `build.sh:1–7` runs `go build -trimpath -o bin/openusage-web .`; it mentions use by keep's update step. The actual local keep configuration declares `openusage-web` as resident, points to that binary, names port 6737, and sets its update command to `build.sh`. The generated LaunchAgent invokes `keep fork openusage-web` with `RunAtLoad=true` and `KeepAlive=true`. Thus local deployment delegates the web process's resident lifetime to keep/launchd; the Go program itself contains no supervisor. [W4, L1]

The app/server source ends at `http.ListenAndServe` with fatal-error exit. It does not install its own login item, update itself, or implement a graceful signal-driven HTTP shutdown. A web restart loses its in-flight refresh guard and boot stamp, and can interrupt an active refresh request. It does not erase OpenUsage's separately persisted cache. [W1]

This arrangement has distinct operational pieces: the signed OpenUsage app/CLI release, the separately built Go dashboard binary, keep's LaunchAgent, and the private HTTPS/tailnet exposure. The web server binds to loopback and implements no user login; the local keep configuration documents tailnet exposure. Tailnet policy, proxy runtime state, keep internals, and crash/reboot behavior were not exercised here. The generated plist demonstrates configured supervision, not current process health or a tested restart guarantee. [W1, W4, L1]

## Realistic Tally options

All options assume entirely new Tally code, four supported providers with multiple accounts, OpenCode-owned accounts/auth/refresh, native macOS UI, personal-tailnet web access, an API, and the required OpenCode companion. The companion's collection access method remains a separate decision.

| Option | Collection/API/web owner | Advantages supported by the references | Costs and unresolved behavior |
|---|---|---|---|
| Swift-centric app-owned runtime | One resident Swift application hosts collection, command handling, API, and bundled web assets; native UI calls the same owner. | OpenUsage demonstrates Swift UI + collection + HTTP in one app and one app/CLI release. Fewest Tally resident processes. | Quit/crash/update of the app interrupts all its surfaces. Swift web-asset serving and the required write API would be new work. The OpenCode companion still needs an interface to this process. |
| Swift-centric background runtime with native shell | A resident Swift helper owns collection/API/web; native app is a client. | Keeps Swift shared domain implementation while allowing the UI to close independently. The reference bundle already demonstrates packaging multiple executables together. | Reference does not demonstrate this helper topology. Requires supervision, single ownership, startup discovery, and coordinated app/helper updates. Two processes do not require two installers. |
| Split native shell plus background runtime | Swift shell; Go or another chosen runtime owns collection/API/web and command handling. | openusage-web demonstrates Go's standard HTTP server and embedded static assets without third-party Go dependencies. Can keep background work independent of native UI. | Requires a cross-language interface and coordinated runtime packaging/update behavior. The existing Go proxy does not demonstrate provider collection, durable commands, or Tally's OpenCode integration. A new split should use one state owner, rather than copy the reference's app/CLI cache-writing arrangement. |

These options do not establish that Go is lighter, Swift is faster, or a helper is necessary. No comparative resource, startup, packaging-size, or development-time measurements were performed. Choosing a background helper solely because a web/API surface exists would contradict the Swift source evidence. Choosing an app-owned process solely to minimize the executable count would leave the undecided availability requirement unanswered.

### Recommendations for the architecture grilling

1. **Decide the lifetime promise first.** Must web reads, API queries, banked-reset redemption, and low-quota advisories work after the user quits the menu-bar app? Separately, must they work when no OpenCode server is running? Those are different conditions, especially with OpenCode owning credential refresh.
2. **Choose one authoritative collection/command owner.** Its interface should hide scheduling, last-good caching, failure/backoff state, and post-redemption reconciliation. Native UI, web, API, and companion are real callers; they justify a shared deep module. That does not by itself justify extra processes or an adapter framework.
3. **Make unavailable, stale, and fresh distinguishable.** A loaded cache and an HTTP 200 are insufficient evidence of a successful current collection pass. Ask what each surface should display while OpenCode is unavailable, credentials are expired, or the provider cannot be reached. The separate collection research should determine how those facts arrive.
4. **Decide restart durability deliberately.** Which state must survive app/runtime/OpenCode restart: last-good quota windows, account attribution, advisory delivery history, pending commands, or redemption outcomes? In-memory notification dedup and best-effort snapshot persistence in the reference answer only part of that question.
5. **Treat installation count and process count separately.** Would one app bundle containing a helper and web assets meet the desired installation experience? Who starts the helper, who stops it, and what does “Quit Tally” mean? If a separate keep-managed deployment is acceptable, is that a personal installation choice or a required part of the product?
6. **Choose the language after these responsibilities are clear.** Is maintaining native Swift and provider/HTTP code in one language preferable, or does the team prefer a background runtime whose HTTP/data tooling it knows better? The required companion already introduces OpenCode-side code; sharing a language there is useful only if concrete domain logic can actually be shared without coupling to OpenCode internals.
7. **Specify update behavior across consumers.** Can a short API interruption be accepted during update? How will a long-lived browser and already-running OpenCode companion detect a changed runtime interface? The reference has a browser boot stamp and bundled CLI, but no equivalent companion-version evidence.

## Verification and remaining gaps

Performed: read-only Git revision/status/diff inspection, cited source reads, static-tree searches for browser persistence, and SHA-256 fingerprints of local modified files and deployment configuration. No source clones were mutated. No builds, tests, provider requests, process restarts, install/update operations, or UI automation were run. Runtime behavior remains unverified in this research session.

The evidence is sufficient to grill process ownership without language prejudice. Remaining research or decision inputs are the OpenCode companion/collection findings, the required standalone lifetime, minimum macOS/architecture support for Tally, the desired installation/update channel, and the acceptable persistence/restart behavior. Actual Swift helper management or a chosen background runtime's packaging should be verified after one of those topologies becomes a candidate, rather than importing the full reference release machinery now.

## Source citations

S citations are immutable OpenUsage source links at `70dea9a8fa21ed205aa9ad625b416a1e7792d5a1`. Line ranges after a citation narrow its listed source when useful.

### S1: Package and runtime requirements

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Package.swift#L1-L72

### S2: Composition, API state, refresh loop, and reset reconciliation

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/App/AppContainer.swift#L62-L179

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/App/AppContainer.swift#L215-L237

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/App/AppContainer.swift#L282-L315

### S3: App lifecycle and native UI

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/App/OpenUsageApp.swift#L14-L98

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/App/StatusItemController.swift#L51-L87

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/App/StatusItemController.swift#L268

### S4: Swift HTTP transport and read-only routes

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/Services/LocalUsageServer.swift#L1-L145

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/Services/LocalUsageAPI.swift#L9-L87

### S5: One-shot CLI and shared read engine

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsageCLI/OpenUsageCLI.swift#L5-L42

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/Services/UsageReader.swift#L22-L146

### S6: Persisted snapshot cache and memoization

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/Stores/ProviderSnapshotCache.swift#L4-L38

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/Stores/ProviderSnapshotCache.swift#L64-L191

### S7: Provider interface, refresh policy, and runtime state

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/Providers/ProviderRuntime.swift#L27-L56

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/Stores/WidgetDataStore.swift#L50-L103

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/Stores/WidgetDataStore.swift#L169-L223

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/Stores/WidgetDataStore.swift#L270-L454

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/Stores/RefreshSetting.swift#L3-L12

### S8: Notification state

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/Stores/QuotaNotificationEvaluator.swift#L13-L83

### S9: Login registration

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/Stores/LaunchAtLoginSetting.swift#L17-L29

### S10: Signed app, CLI, resources, and DMG packaging

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/script/release.sh#L80-L108

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/script/release.sh#L142-L243

### S11: Bundled CLI installation

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/Services/CommandLineToolInstaller.swift#L5-L32

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/Services/CommandLineToolInstaller.swift#L105-L139

### S12: Sparkle activation and publication

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/App/UpdaterController.swift#L43-L100

https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/.github/workflows/release.yml#L148-L222

### W1–W3: Uncommitted local web source

These findings cannot be reproduced from the GitHub base commit alone. Paths are relative to `/Users/max/Projects_personal/openusage-web`; hashes fingerprint the exact working files read on 2026-09-06.

| Citation | File and relevant lines | SHA-256 |
|---|---|---|
| W1 | `main.go:22–105` hosting/proxy; `70–101` refresh route; `113–190` CLI/restart implementation | `f3f04287011d9f63a242991d539296ab5b32eac7b0ba6bbc39b9bcd045adf958` |
| W2 | `static/index.html:194–196` restart disclosure; `215–229` browser state; `407–472` requests/reload/timers | `61ec065b3aef16c7e4d91cd94e18ffb6ae9ae2763d3383c5d544f579e6829509` |
| W3 | `main_test.go:10–45` callback tests | `def6ddd0cacdeee14d0fea5ed07b529fea337b6ca0e5d769488dc67bd9db5baf` |
| W3 | `README.md:58–75` refresh/security documentation | `e8a257c4f15912dfc5ed9bc21dd25329eb2cab81b8bbdcfc8789595bd3bb7fd1` |

Committed baseline for comparison, not a citation for the added restart code:

https://github.com/MaxAnderson95/openusage-web/blob/58ff486a3375ec0599d9c5d60e82be575ed0cc20/main.go

### W4: Unmodified web package/build/assets

https://github.com/MaxAnderson95/openusage-web/blob/58ff486a3375ec0599d9c5d60e82be575ed0cc20/go.mod#L1-L3

https://github.com/MaxAnderson95/openusage-web/blob/58ff486a3375ec0599d9c5d60e82be575ed0cc20/build.sh#L1-L7

https://github.com/MaxAnderson95/openusage-web/blob/58ff486a3375ec0599d9c5d60e82be575ed0cc20/static/manifest.json#L1-L15

### L1: Local deployment evidence

Private local configuration was read only to identify process/update ownership. No tailnet address, device identity, policy payload, or environment values are reproduced.

- `/Users/max/dotfiles/.config/keep/config.yaml:199–215`, SHA-256 `96d502b681bf12dc53801d2899156442fbc13d78b0680c2cbb9a45de49fba450`: resident declaration, binary, port, and build update command.
- `/Users/max/Library/LaunchAgents/keep.openusage-web.plist:5–16`, SHA-256 `17c18bb0a237da6e0f4649cdf25e92d60c515d3af26cad7f38dde57cdc71e573`: generated LaunchAgent command, RunAtLoad, and KeepAlive configuration.
