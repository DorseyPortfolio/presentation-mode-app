# Build 12 source publication — ProductionMac

Prepared on 2026-10-14 on ProductionMac for the explicitly approved destination, [DorseyPortfolio/presentation-mode-app](https://github.com/DorseyPortfolio/presentation-mode-app). This publication contains source and documentation. It does not merge a PR, create a release, install an app, or start live outputs.

## Handoff provenance

| Item | Verified value |
| --- | --- |
| Supplied archive | `presentation-mode-productionmac-handoff.tar.gz` |
| Archive SHA-256 | `7efc0a4536acca41f413c5487e2ae0c147bf322849dfdad902807cdeaf0483cb` |
| Supplied source/docs HEAD | `2e2d4959392ce55ea919fcf1d32f50850e0fa65c` |
| Build 12 implementation | `fd492cc67b616945f601c869e5d11c1d5b05c5ee` |
| Existing PR #1 branch/base for this change | `agent/presentation-mode-0.4.3` at `131fdece8b8b6dd2da67360bb5b352a4790737fb` |
| Main at reconciliation | `b5b17cae6c820fa1c7557f26cecb95663cb4d56c` |

The outer archive was inspected before extraction: 11 ordinary files, no absolute/traversing paths, links, special files or duplicate members. All 10 internal SHA-256 entries passed. The nested source archive was inspected with the same path/type checks; its 108 files matched the Git checkout byte for byte. `git bundle verify` confirmed complete history and the expected branch head; `git fsck --full` passed.

The separately supplied Downloads handoff Markdown describes build 11 and an older source HEAD. It was retained locally as an input and was not used to replace the current bundled build 12 record.

The original ProductionMac checkout was clean at `131fdec` with the expected GitHub remote. Publication uses a separate clone in the task workspace. The new `feature/room-setup-preview` draft targets the existing PR #1 branch so the eight supplied commits can be reviewed without changing PR #1 or main. No rebase, merge or force-push is needed. The existing [PR #1](https://github.com/DorseyPortfolio/presentation-mode-app/pull/1) remains a separate draft to main.

The publication supplement updates README/preview installation instructions, labels historical handoffs, and adds this verification record. The supplied implementation, package manifest, app identity and build script remain unchanged from `2e2d495`.

## ProductionMac checks

Environment: macOS 15.7.4 (24G517), arm64, Apple Swift 6.1.2, Apple Git 2.39.5, Xcode command-line tools.

`sh Tests/Offline/run.sh` passed:

```text
PASS: 46 scheduler/pixel cases (including 20 injected failures and 10s mixed-cadence simulation)
PASS: 20 unarmed session lifecycles; no device enumeration or output calls
PASS: validation launch/network policy
PASS: production launch/network policy
PASS: Largo migration, direct/pair validation, collisions, unsupported modes/cards, versioned persistence and corrupt-data preservation
PASS: four-card inventory, connector grouping, pair links/common modes, direct transitions, duplicate rejection, rescan preservation, missing/inactive/unknown cards, rational timing and app-format limits
```

`sh Packaging/build-app.sh` passed with release optimization (49.37 seconds), including `codesign --verify --deep --strict`. The generated local app reports `com.wcmedia.PresentationMode.SettingsPreview`, 0.5.0/build 12. Its executable SHA-256 is `01a2cf0a6602f1dd4ec1a1b504fa3c31e64d55d17aa595ebc236afc4f3222196`; this is a local verification artifact, not a published release binary.

The native lifecycle tests compile with `PM_OFFLINE_TEST_BUILD`, preventing hardware initialization. No app, hardware probe or playout session was launched for publication. Stopped-output UI/persistence and installed normal-launch evidence below comes from the supplied handoff, rather than a new physical test on ProductionMac.

The publication review found no credential-pattern matches in the new commit history, no private user-home paths, and no tracked build caches, generated apps/installers, preferences, machine snapshots or rollback files. Existing vendor SDK/runtime files and license notices are retained from the repository. Largo endpoint identifiers remain intentional source/profile fixtures. The transfer bundle, patches, raw build logs, and archives remain local rather than being added to Git.

GitHub reconciliation returned zero configured Actions workflows, no rulesets, and no branch protection on main or `agent/presentation-mode-0.4.3`. There are therefore no configured required CI checks at this checkpoint; local verification is recorded explicitly. Remote branch, PR draft state and commit checks are verified after publication and reported with the PR.

## Current behavior and evidence limits

- Build 12 is 0.5.0, bundle ID `com.wcmedia.PresentationMode.SettingsPreview`. Normal launch starts in Production Mode with outputs stopped; Canva Mode starts hardware without a developer arming command. Companion remains off by default; explicit preview opt-in is loopback-only on 19876 with no Bonjour.
- The hardware-first white two-pane Setup uses actual SDK output names, Direct / Fill + Key, reserved Key rows, named profiles and common supported timings. Earlier build 11 stopped-output UI checks passed for pairing/unpairing, Revert/Apply and persistence; build 12 retained that layout/profile implementation.
- The supplied record confirms build 12 is installed on Pro1 and opened normally with saved configuration preserved. Its physical LED-wall, side-screen and confidence-screen test is **unconfirmed**. Earlier acceptance of the fixed Largo 0.4.5 app is not candidate acceptance.
- Read-only discovery in the supplied record found two DeckLink 8K Pro cards. Four-card behavior is covered by synthetic offline cases only.
- The pipeline supports progressive 1920×1080 playback at 23.98/24/25/29.97/30/50/59.94/60 only, subject to device support. Other reported formats are inventory information. Capture is requested at 59.94 fps; audio is not forwarded.
- Physical playback/cadence, NDI receivers, ProPresenter handover, sustained operation and failure recovery remain part of coordinated room testing before release. This source publication adds no deployment or live-output authorization.
- No Companion repository changes are included.
