> [!WARNING]
> This project is a work in progress. It is still being built and is not ready for use.

# Tally

A personal macOS AI subscription usage tracker for the menu bar, mobile web, and REST API. Tally collects stored Anthropic, OpenAI, OpenCode Go, and xAI/Grok subscription Accounts.

Recorded activity has reviewed API-equivalent estimates. Native, web, REST, and the independently installed companion share one owner's readings and durable reset commands. Native and web require inline confirmation before submitting a reset.

The independently installed [OpenCode companion](companion/README.md) registers one `tally` model tool for status, Account list/detail, activity and refresh queries. Its description encourages periodic usage checks. It supports REST API major 1 and an optional personal-tailnet base URL.

Provider viability findings are in [docs/RESEARCH.md](docs/RESEARCH.md).

## Build and install

Requires Apple Silicon macOS 26+, Swift 6.3, and Node 22.12+ on the build machine. The packaged app contains its executable and compiled React web assets; Node is not used at runtime.

```sh
bash scripts/build-app.sh
mkdir -p "$HOME/Applications"
ditto build/Tally.app "$HOME/Applications/Tally.app"
open "$HOME/Applications/Tally.app"
```

Icon sources are the SVGs in `assets/`; `bash scripts/make-icons.sh` regenerates `assets/Tally.icns`, the PNG sizes, the web favicon and PWA icons, and the menu bar glyph resource (needs `librsvg` and `imagemagick` from Homebrew).

Copy the complete app to `~/Applications/Tally.app` before first setup. First launch registers that main app for launch at login; Settings can disable it or open macOS Login Items when approval is required. No helper is installed. See [installation and update instructions](docs/INSTALLATION.md) and [assembled verification](docs/verification/installation.md) for tested behavior and remaining physical/tailnet checks.

Click Tally's menu bar glyph to open the 360px native popover. Closing it leaves collection and HTTP running. Quit Tally stops both. The app collects on launch, wake, and every two minutes. Refresh schedules collection with in-flight joining and a 15-second minimum between attempts. GET requests read the owner's cache only. Failed collection keeps last-good readings stale; recognized Accounts restore cached readings as stale after restart.

The web app and `/api/v1/status`, `/api/v1/accounts`, `/api/v1/accounts/{id}`, and `POST /api/v1/refresh` use loopback port **7483** by default:

http://127.0.0.1:7483

Refresh accepts `{}` or `{"accountIds":["opaque-account-id"]}` as `application/json`. An empty Account list requests activity only. Every valid explicit refresh schedules activity independently of provider cooldowns. Unsupported Go groups have successful null observations after collection.

`POST /api/v1/accounts/{accountId}/redemptions` accepts `{"operationId":"client-UUID","creditId":"optional-explicit-credit-ID"}`. Omit `creditId` for expiry-ordered selection from a fresh preflight. Submission returns 202 while pending or 200 for a retained outcome, with `Location` equal to `resultUrl`. Retry submission with the same UUID and original request, or read `GET /api/v1/redemptions/{operationId}`. A consume can spend one real credit and requires an explicit user request targeting that Account. Tally never automatically retries the provider mutation.

Unknown outcomes block the Account and proven same or uncertain upstream targets across database namespaces. Explicit `POST /api/v1/redemptions/{operationId}/acknowledge` with `{}` releases the block only after durable acknowledgement, keeps the outcome unknown, and sends nothing to OpenAI. Command records live in `~/Library/Application Support/Tally/redemptions.sqlite`, independently of inventory and reading caches, without automatic pruning. Removing an Account or switching the OpenCode database retains its operations. Storage failure declines new consumes; an interrupted possible send recovers as unknown. Quit waits at most 15 seconds for redemption work. See [durable redemption verification](docs/verification/durable-redemptions.md).

`GET /api/v1/activity?range=today|yesterday|last30days` returns cached retained OpenCode activity; omitted range defaults to Today. Native and web have the same ranges, five recorded token components, recorded cost, provider/model breakdowns, and exactly 30 calendar trend buckets. Activity scans run independently every two minutes, on launch/wake, and on valid explicit refresh. History belongs to recorded providers in the selected local database, never current Accounts. Zen is excluded. Failed scans preserve stale last-good views in their original timezone; successful scans replace totals, including source deletions. See [recorded activity verification](docs/verification/recorded-activity.md).

API-equivalent estimates use release-bundled revision `2026-09-07-r1`: reviewed first-party synchronous/global rates and Go reference-token rates, matched by exact provider/model or an explicitly evidenced alias. Cross-provider, daily, provider and model views distinguish scalar, range, partial, unpriced and empty amounts. Anthropic write-duration and Go DeepSeek time alternatives yield ranges. Missing usage, unreviewed models and unknown positive components remain visible exclusions; partial upper values do not bound all activity. Historical negative components remain in recorded tokens but their requests are unpriced because reconstruction is invalid. Recorded cost is separate. These are current reference-token values, not historical bills, subscription charges, quota debit or savings. Old cached views retain their own revision until a successful recomputation. See [pricing bundle and verification](docs/verification/activity-pricing.md).

Native Settings saves a stable listener port, an optional allowed HTTPS web origin, and the OpenCode database path. Saving restarts the listener and switches inventory immediately. Native and web Account Settings share Pin/Unpin, pin ordering, and saved icon colors. Click an Account icon to choose its color. `PUT /api/v1/accounts/{accountId}/color` accepts `{"index":0}` through index 5; `PUT /api/v1/pins` accepts `{"accountIds":["opaque-account-id"]}` in display order, with an empty list unpinning all Accounts. Both return the updated Accounts response and use the same Host, Origin, and JSON policy as other mutations. Empty and all-unpinned inventories retain the plain menu bar glyph. Port collision does not select another port or stop native collection. Retry starts a fresh listener. Configure any personal Tailscale HTTPS proxy independently to forward to `127.0.0.1:7483`, preserve the configured origin's Host, and add that exact HTTPS origin in Tally settings. Tally does not configure Tailscale. No tailnet exposure is required for local use.

Native and web quota rows use blue bars normally and red bars with an early-limit countdown when average usage projects exhaustion before reset. Warnings require fresh readings, at least 5% usage, and at least 60 seconds or 1% of the window elapsed. An even-pace marker shows the expected remaining allowance. Expanded Account details show reset dates, current-pace forecasts, and active errors; collection metadata is under Technical details. Login-item management, database and listener settings, and quitting the owner remain native controls.

Database discovery follows OpenCode V2: `OPENCODE_DB` if absolute, otherwise `<XDG_DATA_HOME>/opencode/<OPENCODE_DB or opencode.db>`. Unset or empty `XDG_DATA_HOME` uses `~/.local/share`. Finder-launched apps do not inherit shell environment settings, so use Tally's explicit path setting for those overrides or a custom OpenCode channel database. The default beta/dev/latest channels use `opencode.db`; custom channel filenames require the explicit path. Tally opens SQLite with `SQLITE_OPEN_READONLY`, never creates/migrates that database, and does not refresh credentials. Active and inactive supported subscription credentials are included. Zen, API-key authentication for OAuth providers, unknown auth methods, and unsupported integrations are excluded before deduplication. Names remain verbatim; manage names and authentication in OpenCode.

Account IDs, per-database preferences, provider-local color sequences, and last-good readings live in `~/Library/Application Support/Tally/accounts.json`. This file contains token/workspace fingerprints, never raw credentials or workspace IDs. Database identity uses filesystem volume/device, file number, and creation time, so symlink aliases and renames preserve the namespace while a replaced file starts a new namespace. Returning to a recognized database restores its preferences. Successful Account removal clears its pins and readings, retaining its identity color for a recognized return. First nonempty discovery pins the batch; later discoveries start unpinned. Failed or empty discovery does not finish initial setup.

Anthropic and xAI Accounts lose their ID, pins, and cached readings when OpenCode refresh rotates both the access and refresh tokens. An unchanged token proves continuity; the same credential row alone does not. OpenAI Accounts with a known workspace selector preserve identity through token rotation. See [Account identity rules](implementation/ACCOUNT-IDENTITY.md).

## iPhone home screen

Open Tally's configured HTTPS address in Safari while connected to Tailscale. Choose Share → Add to Home Screen, keep Open as Web App enabled if shown, and tap Add. Launch the Tally icon to use its standalone window. If an older shortcut still opens a Safari tab, remove that shortcut and add it again after loading the updated site.

The installed web app respects the iPhone's safe areas and system appearance. After its first successful online load installs the service worker, it can launch a connection screen when the Mac is unreachable. Try again after reconnecting; a browser online event also retries automatically. Usage and reset commands require the running Mac app. The service worker caches only the connection screen, so an online launch always loads the current app and never substitutes cached API responses.

## Checks

```sh
bash scripts/test-swift.sh
npm --prefix web test
npm --prefix web run build
npm --prefix web audit
bash scripts/build-app.sh
build/Tally.app/Contents/MacOS/Tally --collect-once
```

The last command performs real read-only collection using the same owner and prints the public Accounts response, including Account names but no credentials. It never redeems credits. Use the group observation/error fields to distinguish success from a failed collection. The Swift tests use isolated synthetic SQLite databases and sanitized fixtures; they do not open the real credential database. Swift and TypeScript both decode `Tests/TallyTests/Fixtures/accounts.json`. `scripts/test-swift.sh` supports the Testing framework shipped with Command Line Tools without requiring full Xcode.

See [Go runtime verification and source revisions](implementation/GO-RUNTIME.md) for the evidence and scope of this slice.

The wayfinder map tracks the decisions needed for an implementation-ready v1 spec:

https://github.com/MaxAnderson95/tally/issues/1
