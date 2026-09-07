> [!WARNING]
> This project is a work in progress. It is still being built and is not ready for use.

# Tally

A personal macOS AI subscription usage tracker for the menu bar, mobile web, and REST API. The first runnable slice reads stored OpenCode Go Accounts and displays their current quotas.

The accepted v1 specification covers Anthropic, OpenAI, OpenCode Go, and xAI/Grok, including multiple accounts and OpenAI banked-reset redemption. Other providers, durable inventory/cache recovery, complete scheduling, activity, and redemption remain later implementation layers.

An OpenCode companion plugin is planned for model-facing usage queries and reset redemption. Its tool description will encourage periodic usage checks.

Provider viability findings are in [docs/RESEARCH.md](docs/RESEARCH.md).

## Build and run the Go slice

Requires Apple Silicon macOS 26+, Swift 6.3, and Node 22.12+ on the build machine. The packaged app contains its executable and compiled React web assets; Node is not used at runtime.

```sh
bash scripts/build-app.sh
open build/Tally.app
```

Click Tally's menu bar glyph to open the 360px native popover. Closing it leaves collection and HTTP running. Quit Tally stops both. The app collects on launch, wake, and every two minutes. Refresh schedules collection with in-flight joining and a 15-second minimum between attempts. GET requests read the owner's cache only. Failed collection keeps last-good readings stale in memory; restarting currently starts with no readings.

The web app and `/api/v1/status`, `/api/v1/accounts`, `/api/v1/accounts/{id}`, and `POST /api/v1/refresh` use loopback port **7483** by default:

http://127.0.0.1:7483

Refresh accepts `{}` or `{"accountIds":["opaque-account-id"]}` as `application/json`. An empty Account list requests no provider reads. The response explicitly marks activity scheduling unavailable in this slice. The unused Go groups have successful null observations after collection; command recovery storage is explicitly unavailable. Redemption routes do not exist.

Settings saves a stable listener port, an optional allowed HTTPS web origin, and the OpenCode database path. Saving restarts the listener; a database path change requires restarting Tally. Port collision does not select another port or stop native collection. Retry starts a fresh listener. Configure any personal Tailscale HTTPS proxy independently to forward to `127.0.0.1:7483`, preserve the configured origin's Host, and add that exact HTTPS origin in Tally settings. Tally does not configure Tailscale. No tailnet exposure is required for local use.

Database discovery follows OpenCode V2: `OPENCODE_DB` if absolute, otherwise `<XDG_DATA_HOME>/opencode/<OPENCODE_DB or opencode.db>`. Unset or empty `XDG_DATA_HOME` uses `~/.local/share`. Finder-launched apps do not inherit shell environment settings, so use Tally's explicit path setting for those overrides or a custom OpenCode channel database. The default beta/dev/latest channels use `opencode.db`; custom channel filenames require the explicit path. Tally opens SQLite with `SQLITE_OPEN_READONLY`, never creates/migrates that database, and does not refresh credentials. Both active and inactive Go keys are included. Zen is excluded before same-key Go deduplication, which keeps the earliest created entry and then credential ID. Names remain verbatim.

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
