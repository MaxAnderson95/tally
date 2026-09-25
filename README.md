<div align="center">

<img src="assets/png/tally-icon-256.png" alt="Tally" width="120" height="120">

# Tally

**Know how much of your AI subscriptions you have left, before you run out.**

Tally is a macOS menu bar app that tracks your Anthropic, OpenAI, OpenCode Go, and xAI subscription usage. It reads the accounts you already signed into in OpenCode, polls each provider for your current quota windows, and shows what is left and when it resets.

</div>

<img src="assets/screenshots/web.png" alt="Tally in the browser, showing pinned Anthropic and OpenAI accounts with quota bars">

| Menu bar | iPhone |
| :---: | :---: |
| <img src="assets/screenshots/menu-bar.png" alt="Tally's menu bar popover" width="340"> | <img src="assets/screenshots/iphone.png" alt="Tally on an iPhone home screen" width="340"> |

## Install

You need an Apple Silicon Mac on macOS 26 or newer, and [OpenCode](https://opencode.ai) with at least one subscription account signed in.

1. Download `Tally-v0.1.0-macos-arm64.zip` from the [latest release](https://github.com/MaxAnderson95/tally/releases/latest).
2. Unzip it and drag `Tally.app` into `~/Applications` or `/Applications`.
3. Open it. The app is signed ad-hoc rather than notarized, so macOS may block the first launch. If it does, go to System Settings > Privacy & Security and click **Open Anyway**.

Tally picks up your accounts on first launch and registers itself to start at login. Nothing else to configure.

Prefer to build it yourself? See [docs/INSTALLATION.md](docs/INSTALLATION.md).

## How it works

Click the menu bar glyph to open the popover. Tally refreshes on launch, on wake, and every two minutes. The **Refresh** button pulls on demand.

**Manage accounts in OpenCode.** Tally opens OpenCode's credential database read-only. OpenCode and its auth plugins own sign-in and token refresh. Tally uses the stored access token for usage collection, model discovery, and warm-up; it never refreshes tokens or writes to OpenCode's database. Collection works while OpenCode is stopped and stored tokens remain usable.

**Switch accounts from Tally.** Native and web account cards show **Active in OpenCode** and a **Use in OpenCode** button for inactive accounts. The companion supports `{"action":"activate","accountId":"opaque-ID"}` after resolving the account with `accounts`. Switching requires the local OpenCode service and uses its activation API so OpenCode reloads provider state. It changes the selected account for that provider on the Mac running Tally. Pinning and collection remain independent of selection. Selection follows Tally's inventory refresh; an unavailable inventory shows selection as unknown.

**Quota meters turn ember when you are burning too fast.** Each window is drawn as a row of tally strokes, one inked stroke per slice of allowance left. Ink means your current pace fits inside the window. Ember means your average usage projects that you will hit the limit before the window resets, and Tally shows how long you have. The tall mark is the even-pace marker: where you would be if you spread the window evenly. The sentence at the top of the dashboard counts the windows on track to run out and says when the next empty one comes back.

**Pin what you care about.** Pinned accounts appear at the top and their percentages show directly in the menu bar. Everything else groups by provider below. Reorder accounts in Settings, and click an account's icon to change its color.

**The Activity tab counts what you actually spent.** Today, yesterday, or the last 30 days of recorded OpenCode tokens and cost, broken down by provider and model, with a 30-day trend. Tally also estimates what the same tokens would have cost at pay-as-you-go API prices, using the [models.dev](https://models.dev) catalog, which it rereads at startup and every six hours. That estimate is separate from real spend: the Activity tab lists extra usage your providers actually billed this billing period.

Anthropic extra usage, OpenAI purchased credits, and the banked reset count show on each account row. **More** opens exact reset times, pace projections, and the reset credit list. Redeeming a reset always needs an explicit confirmation from you.

## Auto warm-up

Auto warm-up is off by default for every Account. Open the **Warm-up** tab in native Settings, turn on an eligible Account, and choose a model. Models load automatically; warming starts once a model is selected. Off accounts without an applicable five-hour window cannot be enabled and show an explanation. An existing enabled preference stays checked while waiting for quota information and can still be turned off. Menu bar pinning and ordering are in the **Menu bar** tab; startup and connection settings are in **General**. Tally schedules a short prompt after its five-hour window resets, with a random delay of up to 20 minutes and a rotating selection of 20 questions. If normal usage has already started the next window, Tally schedules after that window instead. Provider collection can add a small delay.

Web and mobile Settings have the same **Warm-up** controls and **Menu bar** section. Model lists load automatically when opening Warm-up; preferences are shared with the Mac app and follow the stored OpenCode row across token rotation. Account cards show failed warm-up attempts, and Settings has a **Resume** button after resolving the cause. Schedule dates use the Mac's timezone and remain visible while quota information is unavailable. Launch at login, database location, listener settings, and quitting Tally are managed on the Mac.

Tally sends HTTP requests directly to the selected provider using the selected Account's credentials. It creates no OpenCode sessions or processes and requires no executable or auth-plugin path. The model picker reads the provider's current model list.

Each warm-up reads the selected Account's current stored access token and sends one message request on the chosen model. It does not fetch the model list before sending. The selected model never falls back to another model. A failed request pauses warm-up and displays the reason in Settings. OpenCode or its auth plugin must refresh expired credentials; Tally never calls OAuth refresh endpoints or retries the message. Toggle off and on to resume after resolving an error.

Eligibility follows current quota readings, not plan names. Accounts with only weekly or monthly windows show "Not needed" and send nothing. The enabled preference remains stored so a five-hour window appearing later can resume scheduling. Missing or stale quota data shows "Waiting for quota information". Exhausted applicable allowance and pending reset operations prevent sending. Grok currently reports only a weekly window in Tally.

Warm-up runs only while Tally is running and the Mac is awake. Missed windows do not accumulate. Attempts are saved before sending; an interrupted attempt requires manual resumption. Tally sends each message once and does not replay ambiguous failures. Warm-up consumes subscription allowance and can be subject to provider restrictions; timing and prompt variation do not guarantee provider approval or prevent account suspension.

## On your phone

Tally serves the same interface at `http://127.0.0.1:7483`. To reach it from your phone, point a personal [Tailscale](https://tailscale.com) HTTPS proxy at that port, add the exact HTTPS origin under Settings, then open it in Safari and choose Share > Add to Home Screen.

The web app follows your phone's appearance and safe areas, and shows a reconnect screen when the Mac is unreachable. Tally does not configure Tailscale for you, and no tailnet exposure is needed for local use. Never put this API on the public internet.

## For agents

Tally has a REST API under `/api/v1` on the same port, covering status, accounts, activity, refresh, and reset redemptions. Local clients need no token; requests are limited to loopback and the one HTTPS origin you configure.

Give your coding agent the ability to check your usage:

```sh
npx skills add MaxAnderson95/tally
```

There is also an [OpenCode companion plugin](companion/README.md) that registers a single `tally` tool for the same queries.

## More

- [Installation, updates, and building from source](docs/INSTALLATION.md)
- [Provider research](docs/RESEARCH.md)
- [Architecture decisions](docs/adr) and [verification notes](docs/verification)
