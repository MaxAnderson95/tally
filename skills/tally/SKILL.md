---
name: tally
description: Use when querying or checking API subscription usage, AI subscription quotas, remaining allowance, rate limits, reset times, or recorded token usage and costs. Also use for installing Tally, checking whether it is running, locating its data, or calling its REST API. Covers Anthropic/Claude, OpenAI/ChatGPT, OpenCode Go, and xAI/Grok subscriptions stored in OpenCode.
---

# Tally

Tally is a personal macOS AI subscription usage tracker with a menu bar app, bundled mobile web UI, and REST API. One resident app owns collection and cached readings for every client. Closing the popover leaves it running; quitting the app stops collection and HTTP.

It reads active and inactive supported subscription Accounts from the local OpenCode V2 database. OpenCode owns Account names, authentication, and credential refresh; OpenCode does not need to be running. Zen prepaid usage, API-key authentication for OAuth providers, and environment-only credentials are outside this inventory.

## Find or start Tally

1. Look for `~/Applications/Tally.app` or `/Applications/Tally.app`. Check the process with `pgrep -x Tally`.
2. Discover the saved port and check the API. Run these examples in a shell with `curl` and `jq`:

   ```sh
   set -o pipefail
   tally_port=$(defaults read net.maxanderson.tally port 2>/dev/null) || tally_port=7483
   tally_url="http://127.0.0.1:$tally_port"
   curl --fail-with-body --silent --show-error --max-time 10 "$tally_url/api/v1/status" | jq .
   ```

   A valid status response confirms HTTP is reachable. Check `apiMajor` is `1`, then inspect `owner` and `inventory` for readiness, freshness, and errors. A running process alone does not prove the API or provider collection works.
3. If installed but stopped, open the discovered app, then retry status:

   ```sh
   open "$HOME/Applications/Tally.app"
   ```

   Use `/Applications/Tally.app` instead if that is the installed location. If the process runs but HTTP fails, inspect native Settings for the port and listener error. A port collision leaves native collection running; Tally does not choose another port. Use the native Retry control after resolving the collision.

First launch registers the main app for launch at login. Native Settings shows whether macOS requires Login Items approval. After a crash, reopen the app.

## Install when absent

The source-build path requires Apple Silicon, macOS 26+, Swift 6.3, and Node 22.12+. Check `uname -m`, `sw_vers -productVersion`, `swift --version`, and `node --version` before building. Obtain approval for missing toolchain installation under the agent's normal dependency rules.

Use an existing Tally checkout. If none exists, clone the repository into the user's chosen projects directory:

```sh
git clone https://github.com/MaxAnderson95/tally.git
```

From the repository root:

```sh
bash scripts/build-app.sh
codesign --verify --deep --strict build/Tally.app
mkdir -p "$HOME/Applications"
ditto build/Tally.app "$HOME/Applications/Tally.app"
open "$HOME/Applications/Tally.app"
```

The build script installs locked web dependencies, builds Swift and web assets, and ad-hoc signs the app. Copy the complete bundle before first setup. Node is not required at runtime. Finish by checking `/api/v1/status` and `/api/v1/accounts`; report any inventory or collection error separately from installation success.

For a requested update, quit Tally, replace the complete app at the same path, and reopen it. Preserve its data and preferences. For download approval or detailed installation guidance, read `docs/INSTALLATION.md` in the checkout.

## Data and settings

| Location | Contents |
| --- | --- |
| `~/Library/Application Support/Tally/accounts.json` | Account identities, per-database pins/order/colors, last-good provider readings, and cached local activity. Identity evidence contains fingerprints, not raw credentials or workspace IDs. |
| `~/Library/Application Support/Tally/redemptions.sqlite` | Durable reset command history and recovery state. Retained across Account removal and database switching, without automatic pruning. |
| macOS preferences domain `net.maxanderson.tally` | `databasePath`, `port`, `webOrigin`, and login setup state. Normally backed by `~/Library/Preferences/net.maxanderson.tally.plist`; inspect with `defaults read net.maxanderson.tally`. Change runtime settings through native Settings. |
| `~/.local/share/opencode/opencode.db` by default | OpenCode-owned credentials and recorded activity. Tally opens this database read-only and never creates, migrates, or refreshes credentials in it. |

An explicit Tally `databasePath` setting wins. Otherwise discovery uses absolute `OPENCODE_DB`, or `<XDG_DATA_HOME>/opencode/<OPENCODE_DB or opencode.db>`. Unset/empty `XDG_DATA_HOME` defaults to `~/.local/share`. Finder-launched apps do not inherit shell environment overrides; configure their database path in native Settings.

Use the API for usage queries instead of reading credential tables or editing caches. Retain Tally's data directory during troubleshooting, especially the redemption journal.

## Query subscription usage through the API

Use `tally_url` from the status check above. Local clients need no bearer token. A preconfigured personal-tailnet HTTPS URL can be used instead when querying remotely. Tally must allow that exact external origin/Host in Settings; tailnet setup is a separate task. This API has no additional authentication and must stay on loopback or the trusted personal tailnet.

### Accounts and quota windows

```sh
curl --fail-with-body --silent --show-error --max-time 10 "$tally_url/api/v1/accounts" |
  jq '{status, accounts: [.accounts[] | {id, provider, name, groups}]}'
```

The response contains `{status, accounts}`. All Accounts are included regardless of pinning. Provider IDs are `anthropic`, `openai`, `opencode-go`, and `xai`. Select Accounts by the returned provider/name and use their opaque `id` for detail queries; do not guess IDs or assume one Account per provider.

```sh
# Set account_id to an ID returned by the Accounts endpoint.
curl --fail-with-body --silent --show-error --max-time 10 "$tally_url/api/v1/accounts/$account_id" | jq .
```

Detail returns `{status, account}`. Each Account has `groups.plan`, `quotas`, `extraUsage`, `balances`, `resetSummary`, and `resetDetails`. Each group carries `data`, `observedAt`, `lastAttemptAt`, `stale`, `refreshing`, `nextAttemptAt`, and `error`.

Report Account/provider, window label, `usedPercent`, `remainingPercent`, and `resetAt` from `groups.quotas.data.windows`. Preserve model/scope distinctions and each window's `stale` and `resetState`. Convert reset timestamps using the returned status timezone or the user's requested timezone. Include observation time and errors when readings are stale or unavailable. Null means unavailable or unsupported, never zero usage or unlimited allowance.

### Refresh when needed

GET requests only read cached state. Automatic collection runs on launch, wake, and every two minutes. If the user requests fresh readings or cached data is stale, schedule a refresh:

```sh
curl --fail-with-body --silent --show-error --max-time 10 \
  -H 'Content-Type: application/json' --data '{}' \
  "$tally_url/api/v1/refresh" | jq .
```

`{}` targets all Accounts; `{"accountIds":["returned-account-id"]}` targets selected Accounts; `{"accountIds":[]}` requests activity only. Every valid explicit refresh also schedules activity. The response contains Account schedules and an activity schedule, not completed readings. Inspect their state/reason/`nextAttemptAt`, then re-read the relevant GET endpoint after collection. In-flight work joins and attempts have a 60-second minimum interval; honor cooldowns instead of repeatedly posting refreshes. Failures retain last-good readings marked stale.

### Recorded tokens and costs

For local OpenCode activity, use:

```sh
curl --fail-with-body --silent --show-error --max-time 10 \
  "$tally_url/api/v1/activity?range=today" | jq .
```

Valid ranges are `today` (default), `yesterday`, and `last30days`. The response contains `{status, activity}` with the same group freshness/error envelope. Activity belongs to recorded providers/models in the selected database and includes token components, recorded cost, API-equivalent estimates, and 30 calendar trend buckets. It is not necessarily attributable to current Accounts.

Keep provider-reported subscription quota consumption separate from local recorded activity. API-equivalent estimates are reference-token values, not subscription charges, actual bills, quota debit, or savings. Preserve scalar/range/partial/unpriced/empty distinctions and exclusions; a partial upper value does not bound all activity.

Usage checks and refreshes never require spending reset credits. Never submit a redemption or click a reset-use control without the user's explicit permission for that specific real reset.
