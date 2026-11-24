# Contributing to Breeze

Thanks for helping. Breeze controls fan hardware through a root helper and can move files to the Trash, so changes are reviewed for safety first and features second.

## Before you start

- For anything larger than a small fix, open an issue first so we can agree on the approach.
- Security problems go through [SECURITY.md](SECURITY.md), never a public issue.
- Be kind. See the [Code of Conduct](CODE_OF_CONDUCT.md).

## Setup

Requirements: an Apple silicon Mac, macOS 14 or later, and Xcode 26 (Swift 6.2 tools).

```sh
swift build                                  # debug build
swift test                                   # all tests (Swift Testing)
swift test --filter FanCoreTests             # one target
zsh scripts/build.sh                         # signed, packaged dist/Breeze.app
```

The fan helper only works from the signed, packaged app. You need your own Apple Development identity (set `BREEZE_SIGNING_IDENTITY` if you have more than one). Ad-hoc signing is not supported.

[README.md](README.md) is the behavioral spec, and [CLAUDE.md](CLAUDE.md) gives an architecture overview.

## Ground rules

- **No third-party dependencies.** Use the standard library and Apple frameworks.
- **Keep the safety invariants** in fan control: heat never releases an override (it boosts to 100% instead), firmware readback is verified, fixed 0% means the reported minimum and never a stopped fan, there is only one control session at a time, and Apple automatic mode is restored on quit, disconnect, heartbeat timeout or error.
- **Cleanup never removes anything without explicit user approval** and never empties the Trash.
- **UI** follows [.interface-design/system.md](.interface-design/system.md). Buttons go through `BreezeButtonStyle` / `.breezeAction()`.
- **Update README.md** when user-facing behavior changes. It documents guarantees such as safety limits and what each scan excludes.
- Add or update tests for new logic. Tests must not change hardware settings, sleep the machine or touch real user files.

## Pull requests

1. Fork the repo and branch from `main`.
2. Keep each PR focused on one change. Match the surrounding code style.
3. Make sure `swift build` and `swift test` pass locally. CI runs both on every PR.
4. Fill in the PR template, including how you tested. Say if you tested on real hardware and which Mac.

PRs are squash-merged into `main`.

## License of contributions

Breeze is licensed under the [GNU GPL v3.0](LICENSE). By submitting a contribution, you agree that:

1. it is your own work, or you have the right to submit it;
2. it is licensed under GPL-3.0 like the rest of the project; and
3. you also grant the Breeze maintainer a perpetual, worldwide, non-exclusive, royalty-free license to distribute your contribution as part of Breeze under other terms, such as through the Mac App Store, whose terms conflict with the GPL.

The project source stays GPL-3.0 either way.
