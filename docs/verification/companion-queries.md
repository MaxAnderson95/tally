# Companion queries

The independent `companion/` package registers one direct model tool named `tally`. Its model-facing input is a flat object supporting status, Account list/detail, activity ranges and refresh scheduling, compatible with Anthropic's object-root requirement. The executor validates action-specific field pairing with a discriminated command schema before any HTTP request. Zod schemas define the concrete REST response types, runtime validation and action-matched output schema together. Loose response objects preserve additive v1 fields at every nesting level. Commands reject unrelated fields.

The companion defaults to `http://127.0.0.1:7483` and accepts a configured HTTP(S) origin for a different saved port or personal-tailnet proxy. It returns structured faults for unavailable transport, incompatible API major, invalid configuration and malformed responses. HTTP faults retain their code, retry time and blocking operation. Refresh verifies major 1 before sending its single scheduling POST; app and companion build numbers need not match. The app remains the only collector and state owner.

## Upstream evidence

Inspected the fetched `anomalyco/opencode` beta revision `be41bc4e7de76637f4c7a94d6110637270bfff37` on September 7, 2026. The upstream beta branch had been force-pushed, so the existing BTCA checkout was left intact and the fetched revision was read with `git show`.

- `packages/plugin/src/promise/tool.ts` defines `ctx.tool.transform`, synchronous editor `add/get/list`, typed schemas and asynchronous executors.
- `packages/schema/src/tool.ts` accepts Effect, Standard Schema or JSON Schema input/output and defines the structured `Result.output` field.
- `packages/core/src/tool/runtime.ts` validates inputs, validates Standard Schema outputs, advertises the output schema and derives model-visible content from structured output.
- `packages/core/src/tool.ts` keeps `codemode: false` tools on the direct model tool list, validates registrations and captures executable snapshots.
- `packages/plugin/src/host.ts` resolves configured local directories via `server` or `index`; the installed package must be configured using its `dist` directory. A package-name install and a local-directory install have different resolution paths.

https://github.com/anomalyco/opencode/blob/be41bc4e7de76637f4c7a94d6110637270bfff37/packages/plugin/src/promise/tool.ts

https://github.com/anomalyco/opencode/blob/be41bc4e7de76637f4c7a94d6110637270bfff37/packages/schema/src/tool.ts

https://github.com/anomalyco/opencode/blob/be41bc4e7de76637f4c7a94d6110637270bfff37/packages/core/src/tool/runtime.ts

https://github.com/anomalyco/opencode/blob/be41bc4e7de76637f4c7a94d6110637270bfff37/packages/plugin/src/host.ts

The rolling V2 plugin guide was read alongside source. Development types are pinned to published `@opencode/plugin` `0.0.0-beta-19278`; installed runtime verification used `opencode2 v0.0.0-beta-19242`. These are separate observations, not a claim that the installed binary was built from the inspected revision. The package exports a structurally checked V2 plugin object; the SDK is needed only for development types, not shipped runtime code. Zod 4.1.8 is its only production dependency.

https://opencode.ai/v2/docs/build/plugins

## Checks

- `npm --prefix companion test`: 10 tests passed. Real local HTTP test listeners exercise every route, default and explicit ranges, JSON refresh bodies, omitted/all versus empty/activity-only lists, encoded IDs, major checks before refresh, all scheduling states, stale/unknown/zero readings, partial pricing, additive fields, Swift credit DTOs, unavailable app, malformed responses, preserved HTTP faults and invalid inputs. Wrong action/DTO pairings fail the output schema.
- `npm --prefix companion run build`: TypeScript production build passed.
- From `companion/`, `./node_modules/.bin/tsc --noEmit --strict --skipLibCheck --target ES2023 --module NodeNext --rewriteRelativeImportExtensions test/tally.test.ts`: test and source type checking passed.
- `npm --prefix companion audit --omit=dev`: zero vulnerabilities. Full development audit reports 11 moderate findings through the OpenCode SDK's OpenTelemetry dependencies, including the upstream W3C Baggage memory-allocation advisory. No forced dependency upgrade was applied.
- `bash scripts/build-app.sh`: TypeScript/Vite build, Swift arm64 release build, app resources and ad-hoc signing passed. `codesign --verify --deep --strict build/Tally.app` passed; `file` identified the executable as Mach-O arm64.
- `git diff --check` passed. This slice changes no Swift or browser implementation; their existing test suites were not rerun here.

## Installed runtime check

Built the companion with `npm pack`, installed its tarball into a separate temporary directory with `npm install --omit=dev`, and configured its installed `dist` directory in a temporary OpenCode location. The install contained two packages: the companion and Zod. The app used a verified `CFFIXED_USER_HOME` override so preferences and recovery files were isolated from the real Tally home. Its synthetic SQLite inventory contained one expired xAI OAuth credential named `Companion fixture`; the owner blocked collection with `credentials_expired`. No real credential database or provider consume was used.

The running packaged app reported API major 1 and build `dedd431` on default loopback port 7483. OpenCode's plugin API reported `tally` active. A temporary verification-only plugin used the actual registry's `get/list` to assert one `tally` registration and exposed its registered executor through a schema-validated RPC. That probe is not part of the companion. Installed beta-19242 defers transform replay until a snapshot is requested, so an empty test session selected a deliberately nonexistent model to force snapshot construction, then returned the expected `Model unavailable` error before any generation. No model/provider request was needed.

Nine running-app checks passed through that registered executor: status, Account list, Account detail, all three activity ranges, targeted blocked refresh, activity-only refresh, and rejection of an invalid range. Account detail preserved null quota data, stale state and `credentials_expired`. Activity preserved its unavailable-source fault because the synthetic database intentionally lacked activity tables. Targeted refresh reported blocked provider collection and an independent activity schedule. The companion also returned a structured `app_unavailable` result when configured to an unused port.

The controlled OpenCode session is `ses_f81da9532ffe53mOO5zK7gXV5V`. Temporary probe and assertion code are under `/private/var/folders/3x/8r6wdjl562z7cr1r0_zwz3q80000gn/T/opencode/tally-companion-probe/`. The probe configuration is removed after verification, and the controlled app is stopped.

This verifies installed plugin registration and registered-executor queries against the real app and running OpenCode. It does not test an LLM choosing the tool, a physical remote-tailnet connection, or live quota collection. Synthetic HTTP fixtures cover populated/stale readings and partial activity. Independent installation and remote configuration are documented in `companion/README.md`.
