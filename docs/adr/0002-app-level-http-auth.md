# HTTP requires app-level auth (password, passkeys, bearer token)

**Status:** accepted. Supersedes the "trust loopback and tailnet clients; no login or bearer token" access rule in SPEC section 9.

## Context

Tally's web UI and REST API were reachable without credentials: Host and Origin allowlists stopped DNS rebinding and cross-site mutations, and Max's Tailscale policy decided who could reach the HTTPS proxy. Max is moving personal services from Tailscale to OpenTunnel, which publishes a local port on a public `https://<route>.<id>.opentunnel.xyz` hostname. Route-name randomness is not access control, so Tally needs its own gate. The model is keep's ADR 0005 (`~/Projects_personal/keep/docs/adr/0005-app-level-auth-despite-tailnet-gating.md`), adopted with the same environment-variable pair, passkeys, and session design.

## Decision

Every route except the SPA shell, its static assets, and the sign-in endpoints under `/api/v1/auth/` requires one of:

1. **Password** (`TALLY_SERVE_PASSWORD`) for browser sign-in. Passkeys are registered from web Settings after a password sign-in, and Face ID or Touch ID replaces the password after that.
2. **Passkeys (WebAuthn)** through `swift-server/webauthn-swift` on the server and `@simplewebauthn/browser` in the web app.
3. **Bearer token** (`TALLY_SERVE_TOKEN`) for the companion, the Tally skill, curl, and Shortcuts.

There is no loopback exemption. OpenTunnel's local client connects from `127.0.0.1` too, so the peer address cannot tell a local caller from the internet.

Tally launches from Finder and login items without a shell environment, so it stores both values in the login Keychain (service `net.maxanderson.tally`, accounts named after the variables) and edits them in native Settings. Clients read the same variable names from their own environment, normally `~/.env_private`.

Browser sessions are stateless HMAC-SHA256 cookies (`tally_session`, 30 days, `HttpOnly`, `SameSite=Strict`) signed with a persistent key. The signing key, the WebAuthn user handle, and passkeys live in `~/Library/Application Support/Tally/serve-state.json`, written owner-only. Cookie-authenticated mutations also need a same-origin `Origin` or `Sec-Fetch-Site`; bearer requests carry no ambient credentials and skip that check. The existing Host and Origin allowlists and the JSON-only mutation rule still apply to every request. Tally refuses to serve when neither secret is set. Token-only disables password sign-in, so no passkey can be added that way.

## Difference from keep

keep derives the WebAuthn origin scheme and the cookie `Secure` flag from `r.TLS` or a loopback `X-Forwarded-Proto`. OpenTunnel ends TLS in its local client and forwards a raw TCP stream (`anomalyco/opentunnel` `crates/opentunnel/src/tunnel.rs`: `TlsAcceptor`, then `copy_bidirectional` to the target), so Tally would see plain HTTP with no forwarding header and build an `http://` relying-party origin that no browser accepts. Tally decides from the allowlisted Host instead: the configured HTTPS web origin's Host is HTTPS (relying-party ID is its host, cookie is `Secure`); `localhost:<port>` is `http://localhost:<port>`. Host is already checked against the allowlist, so a client cannot choose a scheme it did not connect through. `127.0.0.1` cannot be a relying-party ID, so passkeys work at `localhost` and the configured origin only.

## Consequences

- Passkeys are origin-bound. Changing the configured origin, for example a new OpenTunnel route, means signing in with the password and adding a new passkey.
- Rotating the password or token does not end existing browser sessions. Quitting Tally, deleting `serve-state.json`, and relaunching does, and also deletes every passkey. Deleting it while Tally runs does not, because the running server holds the key and passkeys in memory and rewrites the file on the next passkey sign-in.
- Tally is ad-hoc signed, and macOS ties a Keychain item's access list to the creating app's code signature. A rebuilt Tally can prompt once to read its own items; choose Always Allow.
- Local processes running as Max can still read the Keychain item or the state file. App auth is a real gate for the tunnel and a speed bump locally.
