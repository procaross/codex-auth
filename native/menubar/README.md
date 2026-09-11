# Native menu bar companion

A Chinese macOS menu bar app for this fork. The panel uses AppKit's
`NSGlassEffectView` and SwiftUI glass controls on **macOS 26 or later**.
The existing 128 × 128 halftone robot is rendered as individual Canvas dots,
with breathing, a moving scan band, and subtle pointer movement. This is a
native app, not a web view. No image generation or extra image downloads occur
at runtime.

The compact header shows the saved-account count instead of a welcome slogan.
Account names have their own selectable line; hover to reveal the full email.
The current login is labeled independently from the account being previewed.
Switching actions keep a fixed header slot so choosing a saved account does not
shift the subscription record or account list. Subscription records remain saved
login information, not confirmed billing dates.

The quota/news/statistics selector is SwiftUI's native segmented `Picker` at the system's
extra-large control size. macOS owns its material, selection feedback, tracking,
and accessibility behavior. It uses the system accent and intrinsic size, with
no custom glass overlay, painted backing, border, or drag animation. Its resting
appearance and interactive effects follow the OS and system accessibility settings;
it does not apply a continuously refracting custom shader.

## Build and install

Requires Xcode 26+ with its macOS SDK selected, a macOS build of this fork's CLI,
and Node.js **22.21+ or 24+** on the runtime machine when using the proxy.
Node must be on `PATH`, `/opt/homebrew/bin`, or `/usr/local/bin`.
The app bundles the CLI, but does not bundle Node.js.
Adding accounts also requires the official Codex CLI (`npm install -g @openai/codex`).
Native installations and npm's macOS platform packages are discovered in the
standard Homebrew, local, Cargo, and inherited `PATH` locations.

```sh
# Build the CLI with Zig 0.15.1 first; see the main README for SDK compatibility.
zig build -Doptimize=ReleaseSafe
./scripts/build-macos-menubar.sh

# Or provide an already built copy of this fork's CLI:
./scripts/build-macos-menubar.sh /tmp/codex-auth-app ./zig-out/bin/codex-auth

# Install the resulting Codex Auth.app in ~/Applications or /Applications.
# Open it, then click the pixel robot / percentage in the system menu bar.
```

The build targets the host architecture and checks that the bundled CLI supports
it. `ARCH=arm64` or `ARCH=x86_64` can select another architecture explicitly.
The app is locally ad-hoc signed; it is not notarized for general distribution.
Its bundle ID is `com.procaross.codex-auth.menubar`, separate from the existing
notification helper's `com.procaross.codex-auth.notifications`.

## Behavior

- Click **添加账号** under the saved-account count, then complete the official
  browser sign-in. The panel may close while you use the browser; reopen it to
  see progress or cancel. Successful sign-in selects the saved account for
  preview. Adding does not activate it; use **切换** separately, and refresh to
  retrieve its quota. Signing into an existing account updates its saved login.
- Browser login calls the installed official `codex login` with file credential
  storage in a private, temporary `CODEX_HOME`, then runs the bundled CLI's
  add-only `import`. It does not overwrite the active `auth.json` or use shared
  keychain storage. Login waits up to five minutes. Cancellation, failure and
  success remove the temporary directory. Quitting cancels pending login and
  waits for cleanup; an import already saving finishes before the app exits.
- The menu bar and account cards show weekly quota only. Settings can choose
  weekly remaining percentage, a reset countdown, or just the pixel icon. The
  tooltip marks the quota as cached; the countdown updates each minute.
- The panel reads `CODEX_HOME/accounts/registry.json` (schemas 2–3), or
  `~/.codex/accounts/registry.json` when no `CODEX_HOME` is supplied. It resolves
  the current ChatGPT identity from `auth.json`, since the registry can lag
  behind another program's account selection.
- Quota refresh calls the bundled `codex-auth list --api`. The CLI remains
  responsible for API requests and its usual saved-token refresh behavior.
  The app reads structured registry data rather than parsing terminal output.
- Weekly windows are recognized in either the primary or secondary position.
  Missing weekly data is displayed as unknown, with no five-hour fallback.
  Values have a visible snapshot timestamp; API failures retain cached data.
- Subscription dates come only from saved login claims, with the same identity
  checks and filename encoding as the CLI. They are not billing or renewal
  dates, and JWT `exp` is never used. Dates use the local timezone and an
  unambiguous `yyyy-MM-dd HH:mm` format. Hover the information icon for the
  subscription's last-checked timestamp and explanation.
- Selecting a row only previews that account. The card-header switch button calls
  `codex-auth switch <query>` with a uniquely resolving email or alias, then
  verifies the resulting identity. Ambiguous queries are disabled and stdin is
  closed to prevent accidental interactive selection. API-key entries are
  view-only; manage those through the CLI.
- Each account row shows its weekly remaining percentage. Its **…** menu edits
  a local display name and note, changes order, or hides an inactive account.
  Settings restores hidden accounts; the active account always remains visible.
  Hiding does not delete credentials. Display names do not change CLI aliases
  and are never used as account-switch selectors.
- Weekly samples are retained for 31 days. **周额度趋势** shows seven days,
  separating reset cycles so a refill is not drawn as ordinary consumption.
- Native system notifications warn when weekly quota reaches the configured
  threshold (20% by default), then once more at 5%, and on observed recovery.
  Each cycle is deduplicated on disk. Initial snapshots are quiet; stale or
  out-of-order samples do not notify. Delivery defaults to the current account;
  settings can include other visible accounts. macOS notification permission is
  required. Settings includes a test notification and the system settings link.
- Temporary success feedback, including notification tests, expires after four
  seconds and can be dismissed with **×**. Account-save confirmations remain for
  eight seconds. The manual Codex restart reminder stays until dismissed;
  background refresh does not clear it. Error messages do not auto-expire.
- **After switching, restart Codex manually.** The companion does not inject
  credentials into the running Codex app or interrupt its tasks.
- Reset news uses `codex-auth resets --json` and the existing validated public
  feed cache. Announcements, pending plans, and AI forecasts stay distinct.
  Expired forecasts disappear. A passed planned date never proves execution.
  Public news does not establish personal reset-credit eligibility or balance.
- Viewing reset news does not send notifications, enable a second monitor,
  or consume credits. An existing Slack worker continues independently.
- The app refreshes at launch and checks once per minute whether five minutes
  have elapsed since the previous attempt, even with the panel closed. Opening
  the panel and waking the computer also check for a due refresh. Refreshing
  updates the menu bar without opening the panel or starting its animation.
  macOS may coalesce timers; the app does not prevent system sleep. Login,
  switching, and existing refreshes defer automatic work until the next check.
  Failed requests retain cached values and retry at the normal interval.
  Background refresh preserves login/switch feedback. CLI commands run off the
  main thread, with deadlines and no captured credential-bearing output.
- Proxy use defaults to `http://127.0.0.1:7890`; disabling it removes proxy
  variables from child commands without changing shell or CLI configuration.
- Animation and proxy preferences are native toggles. The app follows light /
  dark appearance, Reduce Motion, and Reduce Transparency. Login launch is
  opt-in through Apple's `SMAppService`, and can require System Settings approval.
- Left-click the status item to open or close the panel. Escape or a click
  outside closes it. Right-click offers Open and Quit. There is no Dock icon.

Saved logins use the CLI's existing accounts directory. The app does not keep a
separate token database, log subprocess output, or send account data to the
public reset feed. It uses the existing local CLI installation and its normal
account API behavior. Browser authentication follows
[OpenAI's authentication documentation](https://learn.chatgpt.com/docs/auth).

## Local usage statistics

The **统计** tab shows today, seven days, or thirty days of local token usage,
daily cost/token charts, and a selectable model breakdown. Click a chart date
for its total. Input includes cached tokens; output includes reasoning tokens,
which are not counted twice. Counts are token-metering records, not a guaranteed
number of HTTP requests.

The scanner reads `sessions` and `archived_sessions` JSONL files in `CODEX_HOME`
on a background actor. It streams large files with bounded line buffers, resumes
from saved byte offsets, retries incomplete tails, and detects replaced or
truncated files. Identical counters and archive/fork copies are deduplicated;
inherited events before a fork's creation time are excluded. Only timestamps,
model/provider names, hashed session IDs, and token counters enter the index;
message content and credentials are not copied. Deleted or unavailable logs,
missing counters and unsupported formats can make totals incomplete. Cloud-only
tasks are outside this local view. Log metadata does not reliably identify the
account, so statistics combine all accounts on this machine.

**API-equivalent cost is an estimate, not a subscription bill.** The bundled
price table was checked against [official OpenAI pricing](https://developers.openai.com/api/docs/pricing)
on **2026-09-11**. It uses standard USD rates, separates uncached input, cache
reads and cache writes, and applies documented long-context rules. It excludes
tool fees, Fast/priority surcharges, regional prices, and discounts. The table
is a dated snapshot, not a live price feed. Unknown models/providers, unsupported
cache-write rates, and counter gaps that cannot identify individual requests
are shown as unpriced; their tokens remain visible and the partial amount is
labeled. Historical usage is valued at this price table, not historical rates.

Organization, notification state, and quota samples live in
`CODEX_HOME/menubar/state.json`. The incremental index is
`CODEX_HOME/menubar/usage-index.json`. Both files use owner-only permissions.
The index can be removed to rebuild it; settings and aliases remain separate.
No statistics are uploaded. Initial indexing can take longer on large histories;
subsequent passes process appended data and prune usage older than 31 days.

## Development and validation

```sh
./scripts/test-macos-menubar.sh
# Also exercise real CLI imports using disposable synthetic credentials:
CODEX_AUTH_TEST_IMPORTER=/path/to/codex-auth ./scripts/test-macos-menubar.sh
"/path/to/Codex Auth.app/Contents/MacOS/CodexAuthMenuBar" --demo
"/path/to/Codex Auth.app/Contents/MacOS/CodexAuthMenuBar" --demo --dark
```

Demo mode uses fictional accounts and makes no CLI or account-file calls.
It disables switching and login launch. Its panel has a normal window level
so native window-capture tools can inspect it. Normal operation uses the menu
panel level. `--show` and the first normal launch open the panel; subsequent
regular launches keep it closed.
Quit one preview before starting another. Do not publish real-account screenshots.

The standalone Swift checks cover quota window mapping, JWT identity isolation,
subscription dates, safe snapshot paths, ambiguous account selectors, missing /
malformed registries, expired forecasts, source URL handling, CLI deadlines,
private browser-login staging, cancellation (including a process ignoring
SIGTERM), cleanup, native CLI discovery, hidden refresh, throttling, overlap,
busy deferral, clock changes, and recovery without losing cached quota.
Additional checks cover weekly-only display, account ordering and hidden state,
notification thresholds, recovery retries and deduplication, token pricing,
malformed counters, fork/archive deduplication, partial tails, truncation,
oversized lines, incremental persistence, and private file permissions.
Optional real-CLI integration
checks cover add-only imports, active-login preservation, duplicate sign-in,
and adding the first account. Tests never open a real browser login.
Visual checks should cover light and dark panels, account preview, scrolling,
the animation toggle, Escape, outside-click dismissal, and reopening. Test real
account switching only with disposable fixtures or an explicit intended switch.
