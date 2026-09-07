# Tally OpenCode companion

One OpenCode V2 model tool, `tally`, queries the resident Tally Mac app. The app owns Account inventory, provider collection, credentials, activity, pricing and refresh scheduling. The companion only calls its REST API.

## Install independently

Build and pack the companion from this checkout using Node 22.12+:

```sh
npm --prefix companion ci
npm --prefix companion test
npm --prefix companion pack
```

Install the resulting `tally-opencode-0.1.0.tgz` in a directory you keep independently of the app bundle. For example, from the directory containing that tarball:

```sh
mkdir -p "$HOME/.local/share/tally-companion"
npm install --prefix "$HOME/.local/share/tally-companion" --omit=dev "$PWD/tally-opencode-0.1.0.tgz"
```

Add the installed package's **absolute `dist` directory path** to the existing `plugins` array in `~/.config/opencode/opencode.jsonc`, or to a project's `opencode.jsonc`. V2's local-directory loader looks for `index.js` in that directory. Preserve other configuration. Replace `/Users/you` with the actual home directory:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": [
    {
      "package": "/Users/you/.local/share/tally-companion/node_modules/tally-opencode/dist",
      "options": { "baseURL": "http://127.0.0.1:7483" }
    }
  ]
}
```

Open a new OpenCode session/location after installing or replacing the companion. If an already-loaded location retains the previous plugin, restart OpenCode's background service with `opencode2 service restart` when existing work can be interrupted. Ask the model to call `tally` with `{"action":"status"}` to check the connection. Installing or replacing Tally.app does not install or update the companion. Reinstall an updated companion tarball separately.

The package contains compiled JavaScript and its Zod schema runtime; OpenCode's SDK is a development-only type dependency. No npm package publication or companion release is required for this local tarball installation.

## Connection and compatibility

The default baseURL is the app's loopback origin, `http://127.0.0.1:7483`. Set a different origin when Tally's saved stable port differs. Use an HTTP(S) origin with no path, query, fragment or embedded credentials; the companion appends `/api/v1`.

For remote OpenCode, configure the existing personal-tailnet HTTPS proxy independently to forward to the Mac's loopback port, preserve its external Host, and set that exact HTTPS origin in Tally's allowed web-origin settings. Set the companion's `baseURL` to the same origin, for example `https://tally.example.ts.net`. The machine running the OpenCode server must be able to reach it under your Tailscale policy. There is no separate Tally bearer token. The companion sends no browser Origin header.

Every invoking OpenCode instance sees the inventory and activity of **the Mac running Tally**, not the invoking instance's accounts or records. A remote loopback URL refers to the remote OpenCode server itself; it does not refer to your Mac.

Companion 0.1.0 supports **API major 1**. App and companion release numbers need not match. Additive v1 response fields are accepted and preserved, including inside groups. A different `apiMajor` returns `incompatible_api` with an update instruction. Required-field/type changes return `invalid_response`. Refresh first checks `/status` because its response does not carry an API-major field. Connection failures return `app_unavailable`; start Tally and check the origin/network. Requests have a 15-second timeout, reject redirects, and are never retried by companion code.

## Model actions

| Input | REST request |
| --- | --- |
| `{"action":"status"}` | `GET /api/v1/status` |
| `{"action":"accounts"}` | `GET /api/v1/accounts` |
| `{"action":"accounts","accountId":"opaque-ID"}` | `GET /api/v1/accounts/{accountId}` |
| `{"action":"activity","range":"today"}` | `GET /api/v1/activity?range=today` |
| `{"action":"refresh"}` | Compatibility check, then `POST /api/v1/refresh` with `{}` |
| `{"action":"refresh","accountIds":[]}` | Compatibility check, then refresh activity only |
| `{"action":"refresh","accountIds":["opaque-ID"]}` | Compatibility check, then targeted refresh |

Activity also accepts `yesterday` and `last30days`; omission uses the app's Today default. IDs come from Account responses. Account names need not be unique. An omitted refresh list targets all Accounts; duplicates and unknown IDs follow the app's scheduling contract.

The tool returns `output: { ok: true, action, data }` or `output: { ok: false, action, error }`. Its output schema pairs each action with its concrete REST DTO; `accounts` has list and detail variants. OpenCode makes this structured output model-visible. Invalid model arguments are rejected by OpenCode's input schema before execution.

Models may choose periodic queries and refreshes while working. GETs only read cached state. Refresh returns scheduling immediately, including started, joined, deferred or blocked Accounts and a separate activity schedule. Preserve stale readings and observation times, null versus measured zero, provider cooldowns, unknown applicability, partial history and pricing coverage when explaining results. Recorded activity and API-equivalent estimates do not measure subscription quota consumption. This query companion has no redemption or acknowledgement action.

## Checks and tested revisions

```sh
npm --prefix companion test
npm --prefix companion run build
npm --prefix companion audit --omit=dev
```

See `docs/verification/companion-queries.md` in the Tally source checkout for upstream source revisions, installed OpenCode verification and remaining limitations.
