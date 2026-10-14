# ProductionMac handoff — Presentation Mode

## Current checkpoint

**Build 12 is installed on Largo Pro1 and opens normally. Physical screen verification is pending.** Joseph approved the Settings layout and then requested normal startup without a developer command. The installed app at `/Applications/Presentation Mode.app` is the Settings Preview, bundle ID `com.wcmedia.PresentationMode.SettingsPreview`, version 0.5.0/build 12. It now permits hardware output without an environment variable; opening it starts in Production Mode with outputs stopped. Canva Mode explicitly starts outputs and Production Mode stops them. Companion/network policy is unchanged.

The earlier build 11 preview had already been moved into the Applications path before this update; its identity and executable hash were verified before replacement. Build 11 and its preferences were backed up first. The accepted 0.4.5/build 10 app and production preferences remain in the private known-good rollback, rather than at the current installed app path. No live output was started by the agent during the build 12 update. Joseph has not supplied physical screen acceptance for build 12. His earlier “All three looked correct” acceptance belongs to the earlier fixed Largo app and must not be reused as candidate acceptance.

No source archive transfer or GitHub push has occurred. Only this handoff document is retained as a Library attachment. Publication MUST happen from ProductionMac.

### Direct instruction and deployment authorization

Joseph asked how to arm/disarm the preview and was shown the temporary developer command. He then directly instructed: **“i want it to work on startup not have to run a dev command”**. This prompted removal of the preview-only arming gates, build 12, a rollback backup, replacement of the verified preview in Applications, and a normal launch without the environment variable. This means normal app launch is ready for the operator's Canva Mode action; it does not add launch-at-login, automatic output takeover, network exposure or a release on other Macs. Before that request Joseph explicitly answered “yes” to relaunching the verified preview from Applications with hardware enabled for a screen test. UI automation could not identify the renamed preview correctly, so the user was handed the Canva/Production buttons; physical test outcome remains pending.

## Repository and history

Repository https://github.com/DorseyPortfolio/presentation-mode-app
Branch `feature/room-setup-preview`
Base `131fdece8b8b6dd2da67360bb5b352a4790737fb`
Accepted0.4.5 source snapshot `6ad0c17f398b4d7a6b185eef70f7eb1ad4a120ad`
Hardware-first implementation `485659e4fb55a61b9f7e70795cbec0776add0915`
Build 12 source commit `fd492cc` (full SHA in commits.txt); the bundle branch HEAD also includes the updated handoff/verification documentation.

Full commit list: commits.txt. Local commits preserve accepted0.4.5, initialSetup, UI fixes, dynamic-profile/blank-room controls, hardware-first design final verification and normal-launch build 12. Local snapshot author Codex <codex@localhost>. Original upstream working files/uncommitted changes were preserved; snapshots live in a separate publication repository.

GitHub read-only reconciliation on2026-10-14: app PR#1 is OPEN/DRAFT/unmerged, agent/presentation-mode-0.4.3→main, head131fdec…, mainb5b17cae6c820fa1c7557f26cecb95663cb4d56c. Remote branches returned main and agent/presentation-mode-0.4.3. Recheck on ProductionMac before publication.
Companion repo https://github.com/DorseyPortfolio/presentation-mode-companion-module remains unchanged at1.2.0, head90939be78f50d793864565eeb43b2452195cc239; PR#1 OPEN/DRAFT/unmerged, agent/companion-module-1.2.0→main, based0300e5980ffe052a459c78a58367b890b213104. No Companion package changes are required by this candidate.

## Transfer and clean build

Transfer remains on hold until testing is complete and Joseph authorizes the ProductionMac handoff. The package includes a self-contained Git bundle, complete source archive, binary-safe patches, checksums, notes and build/test evidence. No private preferences, credentials, machine snapshots, rollback app or live configuration backups are included. Vendor SDK/runtime files and licenses already present in the repository are retained. Default Largo endpoint assignments are intentional profile fixtures.

On ProductionMac, verify the transferred archive and its internal checksums, then:

```sh
shasum -a 256 -c SHA256SUMS
git clone presentation-mode-app.bundle presentation-mode-app-review
cd presentation-mode-app-review
git checkout feature/room-setup-preview
git remote set-url origin https://github.com/DorseyPortfolio/presentation-mode-app.git
git fetch origin
sh Tests/Offline/run.sh
sh Packaging/build-app.sh
```

Use a fresh clone and macOS14+ with Xcode command-line tools. Default release optimization remains preview policy. Hardware is available on normal launch; Companion remains disabled by default (explicit opt-in is loopback-only on port 19876, with no Bonjour). Offline native lifecycle tests use PM_OFFLINE_TEST_BUILD and cannot initialize hardware. Packaging refuses production flavor. Existing libraries are bundled; no new network/security permission is needed to build. Alternative patches:01-accepted-045.patch applies on base131fdec;02-setup-preview.patch applies after01 and includes all later changes. Prefer the Git bundle to retain commit history.

After coordinated testing/review, push this feature branch from ProductionMac and create a draft PR targeting agent/presentation-mode-0.4.3 for just the new changes, or coordinate a combined PR to main covering the existing draft too. Reconcile remote changes first. Do not silently merge main, force-push, close existing PRs, publish release binaries or deploy other Macs. Attach any created PR using the supported artifact tool. Remind Joseph to do GitHub publication from ProductionMac after testing is complete; no scheduled reminder or source upload was created here. The handoff document alone is a Library attachment.

## What changed and limits

See SETUP-PREVIEW.md and SETUP-NOTES.md. Main Controls shows Room profile loaded and actual applied name. Setup has one Outputs sidebar of actual hardware names; rightpane Direct/Fill+Key/common timing; selected output becomes Fill; assignedKey row disabled/labeled; Direct/removal frees it. Profile data preserves Largo's accepted mappings. Device models/physical groups/logical output names and actual SDI modes come from SDK; same-card sync and duplicate-use validation remain. Scheduler120000 ticks/s represents23.976 exactly while keeping50/59.94 unchanged physically.

The current pipeline produces progressive1920×1080 at23.98/24/25/29.97/30/50/59.94/60 only, even if hardware reports other formats. Up to16 assignments/32endpoints. Unknown physical groups cannot pair. Inactive/input-only devices are displayed but not enabled. No automatic Desktop Video profile changes. Rescan is explicit; no hot-plug notification subscription. Hardware availability is rechecked at start. Four-card layout is tested synthetically, not on four physical cards.

## Tests and artifact

See LOCAL-VERIFICATION.md, offline-tests.txt and build.txt for completed evidence. No pending offline/UI blocker. The remaining test is Joseph’s physical-output verification of build 12. No additional live test was run while refreshing this handoff.

Installed app: /Applications/Presentation Mode.app
Build artifact: continuation/settings-candidate/dist/Presentation Mode Settings Preview.app
Bundle ID com.wcmedia.PresentationMode.SettingsPreview; version 0.5.0/build 12; ad-hoc signed.
Executable SHA256 b2cc8ef1ff965b7149ae25fb87965e93bb12924f7dd61252cbe73a50195acbc7.

## Migration, signing and rollback

roomProfiles.v1 stores active profile and saved named profiles. Absence migrates to the acceptedLargo route because0.4.5 had no configurable route schema; prior enabledOutputIDs cannot infer fill/key. The existing roomConfiguration.v1 and Companion identity stay separate. Malformed/unknown profile data blocks start and is preserved. Preview has its own preferences; never copy them wholesale into production.

A future release must retain production bundle ID com.wcmedia.PresentationMode.NDI and its existing Companion device identity/settings. Other rooms need reviewed hardware assignments before first output start. Use an authorized stable signing identity via CODE_SIGN_IDENTITY for release; ad-hoc rebuilds do not promise retained Screen Recording permission. No signing/security changes were made to production.

Known-good rollback on Pro1: continuation/rollback/KNOWN-GOOD-045-build10 contains copied accepted app and exported current production preferences; checksum/signature verified. The accepted rollback executable SHA256 is da22143ab981c38a28c290dd2c649130dc266d3068f278586746bb9bca12e20d. Build 11 preview backup and its preferences are separately retained at continuation/rollback/settings-preview-build11. Build 12 retains semantically identical preview preferences; JSON key order may change on save. Older redundant app copies and generated upstream build folders are now in recoverable macOS Trash; old source/configuration backups remain local. Trash was not emptied. Before any authorized replacement, preserve that Mac's current accepted app/preferences, stop candidate output, and restore exact backups only in an agreed maintenance window.

## Remote access

Existing Desktop Commander 0.2.52 Pro1 registration was previously restarted and remote file reading verified. It was run in a managed session, not a new launch-at-login service. Its current availability was not rechecked during this documentation update. No new credentials or permissions were created.
