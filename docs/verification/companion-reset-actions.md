# Companion reset actions

The existing direct `tally` tool supports `redeem`, `redemption` and `acknowledge` with exact Account/UUID/optional-credit inputs. Each success action is paired with the concrete `Redemption` DTO. The schemas preserve additive fields, nullable provider results, acknowledgement state, faults and result URLs. Swift compatibility uses `Tests/TallyTests/Fixtures/redemptions.json` and the current `Sources/TallyCore/Redemption.swift` shape.

Every reset action checks API major 1. A submission returns the app's pending or completed operation without waiting for collection. The companion sends no refresh as part of redemption or acknowledgement. On transport or malformed-response uncertainty after a mutation, it reads the original operation once. If that lookup fails, the structured fault retains the original UUID in its message and instructs further lookup without resend or a replacement UUID. Structured REST rejection faults remain intact.

The tool description and companion README require specific explicit user authorization for every redemption and acknowledgement, clarification of ambiguous Account names, and no implicit active/fallback Account. They describe nullable applicability, provider-decided effects, unknown outcomes and confirmation independent of refresh. These are instructions to the model; the app trusts its local client rather than inspecting the conversation.

## Checks

- `npm --prefix companion ci`: installed the pinned development dependencies. The existing SDK dependency tree reports 11 moderate development audit findings.
- `npm --prefix companion test`: all 15 tests passed. Local HTTP listeners cover exact mutation JSON/routes, optional credit selection, repeated original UUIDs, pending return, every durable state, acknowledgement, conflict/block/storage faults, socket loss followed by original-UUID lookup, unsuccessful lookup uncertainty, invalid UUIDs, incompatible API and unavailable app. The existing ten query checks also passed.
- From `companion/`, `./node_modules/.bin/tsc --noEmit --strict --skipLibCheck --target ES2023 --module NodeNext --rewriteRelativeImportExtensions test/tally.test.ts`: passed.
- `npm --prefix companion run build`: passed.
- `npm --prefix companion audit --omit=dev`: zero vulnerabilities.
- `bash scripts/build-app.sh`: web typecheck/Vite build, Swift release build, app resources and ad-hoc signing passed. `codesign --verify --deep --strict build/Tally.app` passed; `file build/Tally.app/Contents/MacOS/Tally` reported Mach-O arm64.
- Full working diff reviewed against issue #26 and SPEC sections 8-10; `git diff --check` passed. This slice changes no Swift or browser implementation; their test suites were not rerun.

## Installed OpenCode registry

On September 7, 2026, packed the companion from its package directory and installed the tarball in a separate temporary directory with production dependencies only: two packages, companion and Zod. Configured that installed `dist` directory in a temporary OpenCode location. A temporary verification plugin inspected the actual registry with `get/list`, required exactly one `tally`, and exposed its registered executor through schema-validated RPC. The tool implementation was not recreated in the probe.

Installed `opencode2 v0.0.0-beta-19242` registered both plugins as active. A controlled session selected a deliberately nonexistent provider/model to construct the tool snapshot without model generation. Six registered-executor assertions passed: pending submission, duplicate original UUID, operation lookup, dropped submission socket followed by original-UUID lookup returning unknown, acknowledged unknown, and confirmed `already_redeemed` with null window count. Every REST request went to a synthetic loopback listener; no live Account or provider consume was used. The listener and temporary configuration were removed after the check.

Controlled session: `ses_f81a977a0ffe0VMhqog2LjN5jh`. Probe and assertion files remain outside the repository under `/private/var/folders/3x/8r6wdjl562z7cr1r0_zwz3q80000gn/T/opencode/tally-reset-probe/`.

Rechecked the current upstream Promise tool editor and schema source at fetched beta revision `11e2e0a59ff08367c6ea2e21fb08be020ee2c815`, alongside the V2 plugin guide. The editor still supports typed add/get/list, Standard Schema inputs/outputs and structured executor output. Development SDK remains pinned to `0.0.0-beta-19278`; the source revision and installed binary are separate observations.

https://github.com/anomalyco/opencode/blob/11e2e0a59ff08367c6ea2e21fb08be020ee2c815/packages/plugin/src/promise/tool.ts

https://github.com/anomalyco/opencode/blob/11e2e0a59ff08367c6ea2e21fb08be020ee2c815/packages/schema/src/tool.ts

https://opencode.ai/v2/docs/build/plugins

This validates companion mapping and registry execution against controlled REST outcomes. App-side durable consume suppression is prerequisite behavior, not independently re-proven by a synthetic server returning duplicate records. Live redemption effects, remote-tailnet transport and an LLM following authorization instructions remain unverified. No live credit was consumed.
