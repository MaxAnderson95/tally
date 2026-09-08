# Tally OpenCode companion

One OpenCode V2 model tool, `tally`, queries the resident Tally Mac app and submits explicitly authorized banked-reset commands. The app owns Account inventory, provider collection, credentials, activity, pricing, refresh scheduling and durable command recovery. The companion only calls its REST API.

## Install independently

Build and pack the companion from this checkout using Node 22.12+:

```sh
npm --prefix companion ci
npm --prefix companion test
(cd companion && npm pack)
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
| `{"action":"redeem","accountId":"opaque-ID","operationId":"UUID","creditId":"credit-ID"}` | Compatibility check, then `POST /api/v1/accounts/{accountId}/redemptions`; omit creditId for app selection |
| `{"action":"redemption","operationId":"UUID"}` | Compatibility check, then `GET /api/v1/redemptions/{operationId}` |
| `{"action":"acknowledge","operationId":"UUID"}` | Compatibility check, then `POST /api/v1/redemptions/{operationId}/acknowledge` with `{}` |

Activity also accepts `yesterday` and `last30days`; omission uses the app's Today default. IDs come from Account responses. Account names need not be unique. An omitted refresh list targets all Accounts; duplicates and unknown IDs follow the app's scheduling contract.

The tool returns `output: { ok: true, action, data }` or `output: { ok: false, action, error }`. Its output schema pairs each action with its concrete REST DTO; `accounts` has list and detail variants. OpenCode makes this structured output model-visible. Invalid model arguments are rejected by OpenCode's input schema before execution.

Models may choose periodic queries and refreshes while working. GETs only read cached state. Refresh returns scheduling immediately, including started, joined, deferred or blocked Accounts and a separate activity schedule. Preserve stale readings and observation times, null versus measured zero, provider cooldowns, unknown applicability, partial history and pricing coverage when explaining results. Recorded activity and API-equivalent estimates do not measure subscription quota consumption.

## Reset authorization and recovery

Every redemption requires a specific explicit user request to consume one banked reset for a particular Account. Standing permission, low usage and "keep working" do not authorize it. Resolve Account names through `accounts`; ask the user to clarify ambiguous names to an opaque Account ID. Never use an active or fallback Account implicitly. Applicability null means not reported, and zero does not become a client-side eligibility gate. The provider decides which windows reset.

Use one UUID for the authorized operation and retain it. The app handles duplicate UUIDs with the same original Account/credit-selection request; changing that request conflicts. A pending result returns promptly, retaining its UUID, result URL and state. Read progress separately with `redemption`. An HTTP success is not itself a confirmed reset. Confirmation remains independent of failed usage refresh, and `already_redeemed` does not claim that this invocation reset additional windows.

The companion never retries a mutation. After a lost or malformed mutation response it makes one read of the original UUID. If that read succeeds, it returns the stored operation, including any pending or unknown state; for acknowledgement, inspect `acknowledgedAt` and `acknowledgementRequired` rather than assuming acknowledgement succeeded. If lookup fails, `operation_response_unknown` reports uncertainty and the original UUID in the fault message. Read that same UUID again; a missing operation or changed usage does not authorize a replacement UUID or resend.

Unknown requires asking the user before acknowledgement or a new operation. Every acknowledgement requires specific explicit user instruction. It durably releases the block, keeps the outcome unknown and never retries. Tally trusts the local client's authorization claim; the companion does not inspect the conversation or add a standing-permission switch.

## Checks and tested revisions

```sh
npm --prefix companion test
npm --prefix companion run build
npm --prefix companion audit --omit=dev
```

See `docs/verification/companion-queries.md` in the Tally source checkout for upstream source revisions, installed OpenCode verification and remaining limitations.
Reset-action verification is recorded in `docs/verification/companion-reset-actions.md`.
