# Presentation Mode for macOS

Presentation Mode is a native macOS menu-bar app that switches a room between a mirrored presentation desktop and ProPresenter production. **Canva Mode** captures an extended display and sends it to configured Blackmagic DeckLink SDI outputs and optional NDI. **Production Mode** stops capture and playback and releases the DeckLink devices for other production software.

This branch contains **0.5.0 / build 12, Settings Preview**. It opens normally in Production Mode with outputs stopped. Canva Mode starts outputs without a developer arming command. Source publication does not establish physical acceptance: build 12 still needs operator verification on the LED wall, side screen and confidence screen. Four-card coverage is offline only.

See [publication verification](PUBLICATION-VERIFICATION.md) for source provenance and checks, [Setup details](SETUP-PREVIEW.md), [operator labels](SETUP-NOTES.md), and the [normal-launch update](NORMAL-LAUNCH-BUILD12.md).

## Requirements

- Apple silicon Mac with macOS 14 or newer and Swift 6 command-line tools to build.
- Compatible DeckLink hardware and Blackmagic Desktop Video for SDI output. The bridge includes compatibility interfaces for Desktop Video 15.3.1 and 16.0; the selected card/profile must expose active playback outputs.
- An extended display or HDMI EDID emulator for the presentation desktop, plus Screen Recording permission for the built app.
- Optional NDI receivers and a reviewed source name if the room uses NDI.

The current capture and playback pipeline is **progressive 1920×1080**. Playback timings are 23.98 (24000/1001), 24, 25, 29.97 (30000/1001), 30, 50, 59.94 (60000/1001), and 60 fps, subject to device support. Other modes reported by the hardware are inventoried but cannot be selected for playback. Capture is currently requested at 59.94 fps; selecting another output timing does not change that capture request. Audio is not captured or forwarded.

## Build and offline verification

From a fresh checkout on macOS:

```sh
sh Tests/Offline/run.sh
sh Packaging/build-app.sh
codesign --verify --deep --strict "dist/Presentation Mode Settings Preview.app"
```

The offline suite covers scheduler/pixel behavior under ASan/UBSan, native lifecycle failures with hardware disabled at compile time, network policies, profile migration/persistence/corruption, and synthetic hardware inventories. It never initializes DeckLink hardware.

The packaging script builds with release optimization, bundles the existing NDI runtime and license notices, and signs ad hoc by default. The app identity is `com.wcmedia.PresentationMode.SettingsPreview`, version 0.5.0/build 12. An authorized stable signing identity can be supplied through `CODE_SIGN_IDENTITY`; ad-hoc rebuilds may require Screen Recording permission again. Production packaging is refused pending release review. Generated apps, build caches, installers and local diagnostics stay out of Git.

No release or installer is created by this source publication. Building does not install, launch or start the app. See [preview setup instructions](Packaging/INSTALL.txt) before an authorized installation or hardware test.

## Configure a room

1. Open the built Settings Preview normally. It starts with outputs stopped.
2. In **Controls**, select the extended Canva display. The room summary shows **Room profile loaded** and the applied profile name.
3. In **Setup**, use the white two-pane layout: the **Outputs** sidebar lists actual SDK output names; the right pane configures the selected output.
4. Choose **Direct** for one picture output, or **Fill + Key** with the selected output as Fill. Choose an eligible unused Key on the same synchronization-capable physical card and a common supported timing.
5. A Key output is labeled **Key source for [fill output name]** and reserved from independent editing. Changing the Fill to Direct or removing its assignment releases the Key in the draft.
6. Apply only while outputs are stopped. Apply saves the profile without starting playback; Revert discards unsaved changes. New room starts with no assignments; Duplicate copies the current assignments into a new draft.
7. Enable NDI only if needed and set the exact sender name expected by the room's receiver.

The initial profile preserves the accepted Largo mappings. Review assignments against the actual hardware before using it in another room. Room profiles are stored separately in `roomProfiles.v1`; existing `roomConfiguration.v1` and Companion identity remain separate. Malformed or unknown profile data is preserved and blocks start.

Discovery runs at launch, Rescan, Apply and output start. It does not change Desktop Video profiles, connector mappings, or activate hidden outputs. Inactive/input-only devices are visible but unavailable for assignment. Unknown physical-card grouping prevents Fill + Key pairing; duplicate use and unsupported pair timings are rejected. The current limit is 16 assignments / 32 endpoints. Hot-plug notification subscription is not implemented; use Rescan.

## Operate

**Canva Mode** starts configured outputs and captures the selected desktop. Put Canva, Chrome, Keynote, PowerPoint, Zoom or another presentation window on that display. Picture alpha is opaque, active key is white, and stop clears the key before releasing outputs; physical behavior still requires room verification.

**Production Mode** stops capture, NDI and scheduled DeckLink playback, then disables/releases the DeckLink outputs. Confirm ProPresenter can reclaim them during the coordinated hardware test.

Automatic ProPresenter switching is a saved option and defaults off for a new preview configuration. When enabled, opening ProPresenter selects Production Mode and closing it can return to Canva Mode. With automation enabled, Canva Mode is blocked while ProPresenter is running. The preview starts stopped even when the saved option is enabled. Normal launch does not install a login item.

## Companion and NDI policy

The preview's Companion server is disabled by default. Explicit `PRESENTATION_MODE_ENABLE_COMPANION=1` opt-in binds only to loopback on TCP **19876** and does not advertise Bonjour. The production build policy retains TCP **9876** and Bonjour for the separately reviewed production app. The [Companion module repository](https://github.com/DorseyPortfolio/presentation-mode-companion-module) is unchanged by this work.

NDI is independently optional, defaults off for a new preview configuration, and uses a saved source name. The bundled runtime and license notices are retained. Default names include the Mac name and “Validation NDI”; review the name before enabling it in a room.

## Validation and remaining work

Build, offline tests, and strict signature verification pass. Supplied stopped-output UI evidence covers Direct/Fill + Key editing, reserved Key rows, common timings, Revert/Apply and persistence. Those UI checks were performed on the earlier build 11 layout, which build 12 retained. The supplied build 12 record confirms a normal launch on Pro1 with outputs stopped.

Build 12 is installed on Pro1, but physical three-screen verification is unconfirmed. Earlier acceptance of the fixed Largo 0.4.5 app does not establish acceptance of this generalized candidate. Four-card operation has synthetic coverage only. NDI receivers, ProPresenter handover, sustained playback and hardware failure recovery require coordinated room testing before release. Publication does not authorize live output tests or deployment.

## Troubleshooting

- **Screen Recording unavailable:** grant access to the actual built app under System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen it. Ad-hoc rebuilds may change its permission identity.
- **Missing or inactive outputs:** confirm Desktop Video and the current card profile expose playback endpoints, then Rescan. Discovery does not reconfigure the card.
- **Invalid profile or missing saved endpoint:** repair the assignment in Setup or create a new room draft; saved assignments are not silently rewritten.
- **Canva Mode blocked:** inspect the profile diagnostic and automatic ProPresenter switching state.
- **Companion unavailable:** this preview defaults to no server; an explicitly enabled preview accepts local loopback connections on 19876 only.
- **NDI missing:** confirm NDI is enabled and the receiver expects the exact saved sender name.

## Source layout

- `Sources/PresentationMode`: AppKit UI, profiles, inventory model, capture, mode control, Companion API and NDI service.
- `Sources/DeckLinkBridge`: SDK discovery, mode validation, frame conversion, scheduled playback and release.
- `Sources/NDIBridge`: dynamically loaded NDI sender bridge.
- `Tests/Offline`: hardware-disabled tests run by `run.sh`.
- `Packaging`: build/installer tooling, app assets, NDI runtime and notices.
- `Tools` and `Sources/DeckLinkProbe`: hardware inspection utilities, not part of the offline test path.

Older deployment and continuation documents are retained as historical records and are labeled accordingly. Use this README and the current verification documents for build 12.
