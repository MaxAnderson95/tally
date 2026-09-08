# Durable redemptions

The shared `TallyOwner` owns reset commands. Native clients call `submitRedemption`, `redemption`, and `acknowledgeRedemption`; REST exposes the same operations. The command journal is separate from the best-effort Account cache and remains attached to Tally when the selected OpenCode database changes.

## Durable decisions

1. Submission commits the UUID, original Account and credit-selection request, Account name, database namespace, and hashed target evidence before any provider request. No credential or raw workspace is stored in the journal or returned over REST.
2. Preflight joins any active credit collection, then re-reads inventory and verifies usable current credentials and workspace. It respects provider backoff and Retry-After deadlines, without applying the routine refresh debounce. A failed/deferred preflight ends the command. A second inventory read after the list request rejects rotation, replacement, removal, or namespace changes before consume.
3. Selection filters identifiable `available` credits and excludes passed expiry instants. Dated expiry comes first, confirmed nonexpiring next, unknown expiry last, then credit ID. An explicit ID selects only itself; applicability counts and utilization never gate selection.
4. The journal commits the pinned credit and may-send marker before consume. A failed marker commit sends nothing. Failure to retain the known pre-send failure keeps a conservative block until that local result can commit.
5. The provider result commits independently of collection. Lost, cancelled, malformed, unrecognized, or non-200 consume responses remain unknown. A result-storage failure exposes unknown and keeps the block; the resident owner retries only the local result commit on its tick. An already received verdict can become readable once that commit succeeds. After restart, an absent retained verdict stays unknown.
6. Recovery terminates pending records before the marker as failed and those after the marker as unknown. It never resumes provider work. Acknowledgement commits before releasing a block and never resends. Successful acknowledgement removes any pending local result-commit retry for that operation.

SQLite uses rollback-journal mode, `synchronous=EXTRA`, and macOS `fullfsync=ON`. A lifetime file lock excludes a second command owner; journal file replacement during a running process fails required storage. The file is mode 0600 under the app support directory. Damaged storage is not reset to an empty command history. No command records are automatically pruned.

## One-shot transport

Reset requests use a dedicated Network.framework TLS exchange with one connection and one application-data write. It has no HTTP redirect, authentication retry, connection replacement, or replay path. List has a 10-second total deadline; consume has a 15-second total deadline. TLS uses the platform's default server trust verification. The HTTP/1.1 decoder accepts length-delimited, chunked, and connection-close responses, bounds response size to 1 MiB, and declines malformed framing. Unsupported responses produce uncertainty after a possible send.

The consume POST carries `Authorization`, the selected `ChatGPT-Account-Id`, JSON `credit_id`, and the original UUID as `redeem_request_id`. No server replay guarantee is required. TCP delivery retransmission is part of one connection, not a second application request.

## Source verification

On September 7, 2026, fetched Codex `main` and inspected revision `b4373e53ab79df7baadc6805dea54a060b820307` locally through the BTCA workflow. `backend-client/src/client/rate_limit_resets.rs` retains the WHAM list and consume routes and the two request fields. `backend-client/src/types.rs` retains `reset`, `already_redeemed`, `nothing_to_reset`, and `no_credit`; Tally preserves absent/null `windows_reset` rather than the reference decoder's zero default. `backend-client/src/client.rs` constructs the selected Account header.

https://github.com/openai/codex/blob/b4373e53ab79df7baadc6805dea54a060b820307/codex-rs/backend-client/src/client/rate_limit_resets.rs

https://github.com/openai/codex/blob/b4373e53ab79df7baadc6805dea54a060b820307/codex-rs/backend-client/src/types.rs

https://github.com/openai/codex/blob/b4373e53ab79df7baadc6805dea54a060b820307/codex-rs/backend-client/src/client.rs

## Verification scope

`RedemptionTests.swift` uses fake transport, synthetic credentials, commit failures before and after simulated commit, retained crash snapshots, isolated on-disk SQLite, and cancellation-ignoring gates. It checks original UUID retries/conflicts, expiry selection, current credentials, cooldown restoration, recognized/ambiguous outcomes, result-commit recovery, durable acknowledgement, cross-namespace blocks, target changes during preflight, independent Accounts, client cancellation, and bounded Quit. `HTTPTests.swift` checks submit/read/acknowledge statuses, Location, validation, policy rejection, conflicts, and storage/shutdown errors. Swift and TypeScript share `Fixtures/redemptions.json`.

On September 7, 2026, `bash scripts/test-swift.sh` passed 62 tests. The final focused `bash scripts/test-swift.sh --filter redemption` passed all 18 redemption tests, including the on-disk may-send/acknowledgement recovery and file-replacement checks. `npm --prefix web test` passed 10 tests. `bash scripts/build-app.sh` passed the TypeScript check, Vite build, arm64 release build, and ad-hoc signing; its dependency audit reported zero vulnerabilities. `git diff --check` passed.

No provider request, real credential read, or real credit consumption is part of these tests. Current provider behavior, plan-specific reset effects, and an actual TLS exchange to ChatGPT remain unverified. A live redemption is Max's separate explicit trial. Native/web confirmation and warning controls belong to the next presentation layer.
