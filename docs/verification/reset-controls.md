# Reset controls

Native and web credit rows open an inline confirmation naming the Account and one-credit consumption. Cancel only dismisses the confirmation. The pending operation disables every Use action for its Account, with Redeeming on the selected credit. Credit availability and expiry control selection; a null or zero provider-applicable count does not disable an available credit.

The card header retains an accessible unknown-outcome warning independently of credit details. Its explanation says a credit may have been consumed, the outcome stays unknown, and acknowledgement never retries consumption. Acknowledgement releases the block only after the owner durably records it. Confirmed operations with stale or failed collection say "Reset confirmed; usage update unavailable".

## Identity and recovery

The browser saves the UUID in local storage before submitting and declines submission if that write fails. The native Runtime retains operations outside the popover and discovers owner-journal blocks when reading its snapshot. Both clients read existing operations after views reopen. Browser visibility return and app-build reload recover the saved UUID; accepted pending operations are read every second while visible. Closing credit details does not stop this polling. A server rejection preserves its fault, while ambiguous transport and recovery-storage failures retain the existing identity and block.

The owner's journal remains authoritative. Chrome replayed a socket-dropped submission three times in the controlled browser check, all with the same UUID and credit. The synthetic server accepted one operation; the existing owner tests separately verify that repeated submissions cannot cause another provider consume.

## Verification

- `bash scripts/test-swift.sh`: all 64 tests passed.
- `TALLY_PRESENTATION_OUTPUT="$PWD/build/reset-controls" bash scripts/test-swift.sh --filter 'nativePresentationReference|redemption'`: 21 tests passed. Native control tests use the existing ResetScenario transport and journal, reject a second submission while pending, reopen the same operation, retain a failed acknowledgement, and release only after durable acknowledgement. Presentation tests cover expiry and confirmed collection-failure wording.
- `npm --prefix web test`: 15 tests passed. Browser-command tests cover lost submission response, reload identity, Account independence, unavailable local storage, failed and successful acknowledgement, an older read racing acknowledgement, definitive rejection, and expiry eligibility.
- `bash scripts/build-app.sh`: TypeScript check, Vite production build, arm64 release build, app packaging, and ad-hoc signing passed. Dependency audit reported zero vulnerabilities. `codesign --verify --deep --strict build/Tally.app` and `git diff --check` passed.
- The local `tally-reset-browser.cjs` controlled HTTP scenario passed in installed Chrome through the existing external Playwright runner. It checks actual confirmation/cancel, per-Account disabling, null/zero applicability, unknown/spent credits, one-second operation polls, hidden pause, disconnect/reconnect, app-build reload, unavailable-details warnings, acknowledgement failure/success, and confirmed failed-refresh wording. It recorded one accepted operation, three same-UUID HTTP deliveries, two explicit acknowledgement requests, and no JavaScript exceptions.

The browser scenario is in the session's OpenCode temporary directory. Run it with `node /private/var/folders/3x/8r6wdjl562z7cr1r0_zwz3q80000gn/T/opencode/tally-reset-browser.cjs` after `npm --prefix web run build`.

## Visual evidence and limits

`build/reset-controls/native-reset-confirm-{light,dark}.png` renders the real SwiftUI credit details and confirmation at 360px. `native-reset-unknown-{light,dark}.png` renders the warning and acknowledgement while both count and detail data are unavailable. Browser captures `web-confirm-{320,390}-{light,dark}.png` and `web-unknown-{320,390}.png` retain wrapping two-column details and inline controls without horizontal overflow. Images were reviewed directly.

Native verification uses AppKit-hosted SwiftUI state captures and controlled Runtime actions, rather than physical menu-bar clicks or VoiceOver. Phone widths use Chrome emulation, not physical iPhone Safari. Provider transport, real credentials, and live credit consumption were not used.
