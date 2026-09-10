# Native menu bar companion

A Chinese macOS menu bar app for this fork. The panel uses AppKit's
`NSGlassEffectView` and SwiftUI glass controls on **macOS 26 or later**.
The existing 128 × 128 halftone robot is rendered as individual Canvas dots,
with breathing, a moving scan band, and subtle pointer movement. This is a
native app, not a web view. No image generation or extra image downloads occur
at runtime.

The quota/news selector is SwiftUI's native segmented `Picker` at the system's
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

- The menu bar shows the active account's cached five-hour remaining quota,
  falling back to weekly quota when a five-hour window is absent. The tooltip
  identifies the window and marks the value as cached. Open the panel to refresh.
- The panel reads `CODEX_HOME/accounts/registry.json` (schemas 2–3), or
  `~/.codex/accounts/registry.json` when no `CODEX_HOME` is supplied. It resolves
  the current ChatGPT identity from `auth.json`, since the registry can lag
  behind another program's account selection.
- Quota refresh calls the bundled `codex-auth list --api`. The CLI remains
  responsible for API requests and its usual saved-token refresh behavior.
  The app reads structured registry data rather than parsing terminal output.
- Known weekly-only primary windows are shown as weekly quota. Missing
  five-hour data is displayed as unknown, never copied from the weekly window.
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
- **After switching, restart Codex manually.** The companion does not inject
  credentials into the running Codex app or interrupt its tasks.
- Reset news uses `codex-auth resets --json` and the existing validated public
  feed cache. Announcements, pending plans, and AI forecasts stay distinct.
  Expired forecasts disappear. A passed planned date never proves execution.
  Public news does not establish personal reset-credit eligibility or balance.
- Viewing reset news does not send notifications, enable a second monitor,
  or consume credits. An existing Slack worker continues independently.
- Opening the panel refreshes when at least five minutes have elapsed since
  the previous attempt. An open panel checks that interval once per minute.
  When hidden, it starts no new polling and pauses animation; an already
  running request may finish. CLI commands run off the main thread, with
  deadlines and no captured credential-bearing output.
- Proxy use defaults to `http://127.0.0.1:7890`; disabling it removes proxy
  variables from child commands without changing shell or CLI configuration.
- Animation and proxy preferences are native toggles. The app follows light /
  dark appearance, Reduce Motion, and Reduce Transparency. Login launch is
  opt-in through Apple's `SMAppService`, and can require System Settings approval.
- Left-click the status item to open or close the panel. Escape or a click
  outside closes it. Right-click offers Open and Quit. There is no Dock icon.

The app does not store copies of authentication tokens, log subprocess output,
or send account data to the public reset feed. It uses the existing local CLI
installation and its normal account API behavior.

## Development and validation

```sh
./scripts/test-macos-menubar.sh
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
malformed registries, expired forecasts, source URL handling, and CLI deadlines.
Visual checks should cover light and dark panels, account preview, scrolling,
the animation toggle, Escape, outside-click dismissal, and reopening. Test real
account switching only with disposable fixtures or an explicit intended switch.
