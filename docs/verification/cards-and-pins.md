# Cards and pins verification

Checked on September 7, 2026 against the Cards variant in `docs/prototypes/PROTOTYPE-presentation.html` and sections 6, 9, and 11 of `docs/SPEC.md`.

## Automated checks

- `TALLY_PRESENTATION_OUTPUT="$PWD/build/presentation" bash scripts/test-swift.sh`: 34 tests passed. The presentation test renders real SwiftUI/AppKit views without starting collection, generates a normalized four-provider browser fixture, checks the 14-pin reference width, and captures native light/dark cards and details plus empty/all-unpinned inventories.
- `npm --prefix web test`: 7 tests passed, including stable overview ordering, hidden scopes, nullable percentages, credit provenance, and stale observation retention.
- `bash scripts/build-app.sh`: Apple Silicon release build and packaged app succeeded. `codesign --verify --deep --strict build/Tally.app` passed. Foundation resolved all four packaged SVG resources and AppKit decoded each image. The resource lookup supports both the installed app's Resources directory and SwiftPM test execution.
- `git diff --check`: passed.

## Visual and browser behavior checks

Native captures are in `build/presentation/native-360-light.png`, `native-360-dark.png`, `native-details-light.png`, `native-details-dark.png`, `native-unpinned.png`, and `native-empty.png`. Both 1440px reference captures place the real `MenuPins` view, with 14 Accounts, beside a clock. The fitted content stays inside 1440px. The all-unpinned menu glyph measures under 50px. This verifies the reference composition, not fit alongside arbitrary third-party status items or notch arrangements.

Chrome 152.0.7977.76 ran the built SPA with an external, already-installed Playwright runner and a local synthetic HTTP server. The fixture came from the native presentation test, which uses the existing Anthropic, OpenAI, Go, and Grok decoder fixtures. No provider traffic or redemption was involved. Screenshots are under `build/presentation/web-*.png`.

- Light and dark at 320, 390, 999, 1000, and 1440 CSS pixels: 14 cards, no horizontal overflow, 36px hero type, and every bar measured 4px. Expanded Account and reset-credit details retained two wrapping columns at each width.
- At 1000px, the account and activity columns measured approximately 549.6px and 366.4px; at 1440px, approximately 813.6px and 542.4px. Activity was sticky at 1000px and above, and static below it.
- All six browser logo colors matched the specification in each appearance. Bars, text, chips, and warnings remained neutral. Native artwork comes from the same bundled SVG file. The native hero uses 30px type.
- Empty and all-unpinned inventories, a 180-character Account name, long plan text, no quota reading, unknown-duration-only quotas, reset-passed values, Off, measured-zero used-only, bounded, and unavailable extra usage rendered without overflow.
- A failed 15-second poll preserved all 14 cards and displayed the connection error/stale warning. Hidden state stopped requests for 45 simulated seconds; foreground return immediately recovered. The visibility state was simulated explicitly, rather than assuming a headless tab became hidden.
- Changing `appBuild` caused a real browser navigation/reload. Browser checks reported no JavaScript exceptions.

Visual review caught and corrected the native dark card surface, expanded native detail wrapping, and the purchased-credit body's excessive provenance text. Provenance remains in credit details and normalized data.

## Remaining runtime boundary

Native evidence uses AppKit-rendered SwiftUI captures, not an interactive system menu bar click/hover session. Physical iPhone Safari, a real macOS appearance change, and notch placement were not exercised. The browser's appearance was changed through media emulation and native appearance through the view environment.

The activity region intentionally contains an unavailable message until #21 supplies actual recorded activity. Reset chips expose existing credit details; the command interaction ticket supplies Use/confirmation/acknowledgement and accepted-operation polling. No credit was consumed.
