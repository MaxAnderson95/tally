# Installation and manual updates

Tally requires Apple Silicon and macOS 26 or newer. The app contains its native executable, reviewed pricing and logo resources, and matching compiled web assets. It needs neither Node nor a second Tally process at runtime. OpenCode owns authentication; it need not remain running for Tally to read its database.

## Build

On the build machine, use Swift 6.3 and Node 22.12 or newer:

```sh
bash scripts/build-app.sh
codesign --verify --deep --strict build/Tally.app
file build/Tally.app/Contents/MacOS/Tally
mkdir -p "$HOME/Applications"
ditto build/Tally.app "$HOME/Applications/Tally.app"
open "$HOME/Applications/Tally.app"
```

The script installs the web lockfile, typechecks/builds the SPA, builds arm64 release Swift, packages both resource bundles and Web, and ad-hoc signs the result. `CFBundleVersion` includes the source commit and UTC packaging timestamp so rebuilding an uncommitted checkout also changes browser build identity. `Package.resolved`, `web/package-lock.json`, and `companion/package-lock.json` pin dependencies. No release is published by this script.

## GitHub releases

Pushing a SemVer tag such as `v1.2.3` or `1.2.3` runs `.github/workflows/release.yml`. Prerelease and build metadata suffixes are supported; prerelease tags such as `v1.2.3-rc.1` create GitHub prereleases. GitHub's tag filters match candidate tags, and the workflow rejects invalid SemVer before building.

The macOS 26 job uses Xcode 26.6 and Node 22 to run the app build script, set the bundle's short version to the tag's numeric version, re-sign and verify the app, and archive it with `ditto`. A separate Ubuntu job downloads the archive and creates a GitHub release with generated notes and a `Tally-<tag>-macos-arm64.zip` asset. Only the release job has repository write permission. Release builds retain ad-hoc signing and require Apple Silicon and macOS 26 or newer.

## First launch and settings

First launch saves loopback port 7483 and registers the main app with macOS ServiceManagement for launch at login. Settings shows the current login-item state and can disable it. If macOS requires approval, follow the displayed Login Items link. Registration failure remains visible and setup retries on next launch. Collection and HTTP run independently of the popover. Closing it leaves both running; Quit rejects commands, bounds redemption waiting to 15 seconds, and awaits HTTP shutdown. After a crash, reopen the app manually.

Settings accepts a database path, stable port from 1024 through 65535, optional exact HTTPS origin without a trailing slash/path, credentials, query or fragment, a web password, and an API token. Invalid listener settings are rejected before saving. Port collision never selects another port. Native collection continues with a web/API-unavailable message and Retry. Save settings restarts the listener; Retry after failure creates a new server lifetime. OpenCode Account names and authentication stay in OpenCode.

## Authentication

The web UI and API stay off until Settings has a web password, an API token, or both ([ADR 0002](adr/0002-app-level-http-auth.md)). Tally saves them in the login Keychain as `TALLY_SERVE_PASSWORD` and `TALLY_SERVE_TOKEN` under service `net.maxanderson.tally`. Generate long random values, for example `openssl rand -base64 32`, and put the token in `~/.env_private` as `TALLY_SERVE_TOKEN=...` so the companion (through OpenCode's service environment) and shell clients send the same value. Loopback clients need the token too.

- **Browser:** sign in with the password, then open Settings > Sign-in and add a passkey. Later sign-ins use Face ID or Touch ID. A passkey works only at the address it was added from: `http://localhost:<port>` or the configured HTTPS origin. `127.0.0.1` supports the password only. Sessions last 30 days and survive app restarts.
- **Scripts and the companion:** send `Authorization: Bearer $TALLY_SERVE_TOKEN`.

Sessions are signed with a key in `~/Library/Application Support/Tally/serve-state.json`, which also holds the passkeys. Changing the password or token does not sign browsers out. To end every session, quit Tally, delete that file, then open Tally again; this also removes every passkey. A running Tally keeps the key and passkeys in memory and writes them back on the next passkey sign-in, so deleting the file while it runs revokes nothing. Tally is ad-hoc signed, so a rebuilt app can ask once to read its Keychain items; choose Always Allow.

## HTTPS access from other devices

Run a tunnel or proxy that forwards a public HTTPS hostname to `http://127.0.0.1:7483`, or the saved port, and preserves the external Host: OpenTunnel (`https://<route>.<id>.opentunnel.xyz`) or a personal Tailscale Serve proxy. Enter that exact HTTPS origin in Tally Settings and use it as the companion `baseURL`. For example, an origin `https://tally.example.opentunnel.xyz` permits Host `tally.example.opentunnel.xyz` and that browser mutation Origin. An explicit HTTPS port must also appear in Host and Origin. This example is not a provisioned endpoint.

Tally allows its loopback authorities and configured external authority only. Requests for the configured Host are treated as HTTPS, because the tunnel ends TLS and forwards plain HTTP. That Host sets the passkey origin and the `Secure` cookie flag. Mutations require `application/json`; browser Origin must match loopback or the configured origin. Bearer clients may omit Origin. No permissive CORS header is emitted.

On Max's Mac, the rootless Tailscale CLI uses `--socket="$HOME/.config/tailscale/tailscaled.sock"`. Inspect existing exposure with `tailscale --socket="$HOME/.config/tailscale/tailscaled.sock" serve status --json`. Adding a new service can reset approval for other services on this node, so configure and approve Tally as a separate operational task.

## Download approval and replacement

This personal app has ad-hoc signing, without Developer ID or notarization. For a downloaded release, extract it, copy the complete app to `~/Applications`, and try opening it. If Gatekeeper blocks it, use System Settings > Privacy & Security > Open Anyway and approve that specific app. Download/quarantine approval still needs a physical check; the tested bundle was built locally.

For an update, Quit Tally and replace the complete `Tally.app` at the same installed path, then open it. Do not replace only the executable or Web directory. Keep `~/Library/Application Support/Tally` and app preferences: these retain identity/pins, readings, stable port and durable command history. Browsers reload when the returned app-build identity changes. Refresh or open the page again if the app is unavailable during replacement. The companion is separately packed and installed according to `companion/README.md`; API major 1 accepts additive fields and does not require matching release numbers.

## Tested environment

September 7, 2026: macOS 26.6.2, Apple Silicon, Swift 6.3.2, Node 22.22.2, installed OpenCode `v0.0.0-beta-19242`; companion development SDK `0.0.0-beta-19278`. Hummingbird is pinned to `80b4445a88503fc6c8062ec40631eb7f9d93b837`, React 19.2.4, TypeScript 5.9.3 and Vite 7.3.6. Source-revision evidence is recorded in `implementation/` and `docs/verification/`; inspected upstream source revisions are separate from the installed OpenCode binary version.
