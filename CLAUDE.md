# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project rules (from AGENTS.md)

- **Leave testing to the user.** Don't run `swift test`, the transport script, the app, or any desktop/computer-use UI checks unless the user explicitly asks. Make the change and report what changed.
- Use the **Sosumi MCP** (`mcp__sosumi__searchAppleDocumentation`, `mcp__sosumi__fetchAppleDocumentation`) first for Apple docs (Swift, SwiftUI, macOS frameworks, HIG). The user may call it "susomi". Fall back to Apple's website only if Sosumi doesn't cover it.

## What this is

Breeze: a native macOS 14+ SwiftUI app for Apple silicon (SwiftPM, Swift 6.2 tools, **no third-party dependencies**). It covers fan control, system statistics, battery, network monitoring, storage exploration and cleanup, and a menu-bar widget. `README.md` is the detailed behavioral spec. Keep it accurate when behavior changes, because it documents user-facing guarantees such as safety limits and what each scan excludes.

## Commands

```sh
swift build                              # debug build
zsh scripts/build.sh                     # release build + package/sign dist/Breeze.app (needs an Apple Development identity; override with BREEZE_SIGNING_IDENTITY, output with BREEZE_APP_PATH)
swift test                               # all tests (Swift Testing, not XCTest)
swift test --filter FanCoreTests                 # one test target
swift test --filter customCurvesInterpolateAndClampEndpoints   # one test (tests are top-level @Test funcs, no suites)
zsh scripts/verify-helper-transport.sh   # signed-process socket auth fixture (Tests/HelperTransport/main.c)
dist/Breeze.app/Contents/MacOS/BreezeHelper --status
```

Launch flags for jumping to a page: `--statistics`, `--processes`, `--network`, `--this-mac`, `--battery`, `--checkup`, `--scan-folder /abs/path` (handled in `Sources/FanApp/BreezeApp.swift`).

Helper approval (SMAppService) only works from the signed, packaged app. Ad-hoc signing is not supported.

## Architecture

Four executables built from shared library targets (`Package.swift`):

- **Breeze** (`FanApp`): the unprivileged SwiftUI app. `AppModel` owns the per-feature models (`*Model.swift`), and each model has a matching `*View.swift`. `BreezeMenuBarController` and `BreezeWidgetView` run the menu-bar widget. Shared visual style lives in `BreezeStyle.swift`.
- **BreezeHelper** (`FanHelper`): the root LaunchDaemon that does all SMC fan writes. It is registered via `SMAppService` using `scripts/local.breeze.fancontrol.helper.plist` and bundled at `Contents/MacOS/BreezeHelper`.
- **BreezeWidgets**: the sandboxed WidgetKit extension, packaged by `scripts/build.sh` as `Contents/PlugIns/BreezeWidgets.appex`. It reads `WidgetSnapshot` (FanCore) from the team-prefixed app group the app writes to.
- **BreezeMCP**: a standalone MCP stdio server that exposes the cleanup inventory to Codex/Claude Code (four tools: `cleanup_summary`, `list_items`, `inspect_items`, `propose_cleanup`).

Library targets:

- `CHardware` (C): the AppleSMC IOKit user client, Unix-socket listen/connect/send/receive, peer audit-token + code-signature authentication, CPU/memory/process sampling. Every privileged or low-level call goes through here.
- `FanCore`: `SMC` key handling, `Cooling` (curve/target controller, boost hysteresis), wire models (`Command`/`Reply` in `Models.swift`), and `Wire` (newline-delimited JSON over the socket). `HelperIdentity` holds the socket path and signing identifiers.
- `StorageCore`: the folder scanner and duplicate detection (`StorageScan`) plus the cleanup catalog/scanner/execution for dev tools, projects, Xcode, Android, Docker, AI models, Downloads, and apps (`Cleanup*.swift`).
- `CleanupAssistant`: `AssistantStore`/`AssistantSnapshot`, the file bridge between the app and BreezeMCP in `~/Library/Application Support/Breeze/CleanupAssistant/` (dir `0700`, files `0600`, snapshots expire after 4h, one pending proposal).
- `NetworkCore`: interface readings, TCP probes, `networkQuality` speed test, LAN discovery (ICMP/TCP/ARP/Bonjour).

### Fan control flow

App `ControlSession` (actor) → `breeze_connect` to the launchd socket in `/var/run` → verifies the peer is root → exchanges `Command`/`Reply` JSON. The helper authenticates the client by audit token, the exact signing identifier `local.breeze.fancontrol`, and its own team. The helper runs the cooling controller loop itself, independently of the UI, and restores Apple automatic mode on quit, disconnect, a 6s heartbeat timeout, or an error. Sleep is an explicit paused state.

The helper also runs the charge limiter (`ChargeController` in `FanCore/Charging.swift`, `.charge` command) and re-enables charging whenever the session ends.

Safety invariants to preserve: heat never releases an override (it boosts to 100% instead), firmware readback is verified, fixed 0% is the reported minimum (never stopped), and there is only one control session at a time. `Monitor` in `ControlSession.swift` does unprivileged read-only SMC sampling for the UI.

### AI cleanup flow

`CleanupAssistantRunner` launches the user's own `codex`/`claude` CLI directly (argument arrays, no shell, private temp dir, model API-key env vars stripped). It wires up BreezeMCP for that one run. The CLI writes a proposal through `propose_cleanup`. The app polls for it and maps the opaque IDs back to the live inventory. Removal always requires explicit user approval in the Review step.

## UI conventions

`.interface-design/system.md` holds the design system. Key rules:
- Buttons go through `BreezeButtonStyle` / `.breezeAction()`. Heights are 34 (standard), 28 (compact), 24 (mini), and 38 (large). Mint is for primary actions, neutral for supporting ones, and red for destructive ones.
- Liquid Glass applies on macOS 26+, with standard materials on 14–15 and opaque surfaces under Reduce Transparency or Increase Contrast.
- Cleanup is a full-page Scan → Choose → Review → Finish journey. Sheets are only for optional inspection or setup. Nothing is ever removed automatically, and Trash is never emptied.
