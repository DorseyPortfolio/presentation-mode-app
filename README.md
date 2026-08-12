# Presentation Mode for macOS

Presentation Mode is a native macOS menu-bar app that lets an operator switch a room between a simple mirrored presentation desktop and normal ProPresenter production output.

In **Canva Mode**, the app captures one extended Mac display and sends the same picture to every selected Blackmagic DeckLink SDI output. It can also publish an optional NDI source. In **Production Mode**, it stops capture and releases those devices so ProPresenter can claim them. If ProPresenter starts, the app automatically returns to Production Mode.

> Hardware safety: the app discovers the endpoints exposed by the current Blackmagic Desktop Video profile. It does not activate subdevices or change card profiles, connector mappings, or saved Desktop Video settings.

## Requirements

- Apple silicon Mac (M1 or newer)
- macOS 14 Sonoma or newer
- Blackmagic Desktop Video 15.3.1 or newer
- A compatible DeckLink card and connected SDI destination
- For the presentation desktop, a 1080p60 HDMI EDID emulator or another dedicated extended display
- Optional: an NDI receiver and Bitfocus Companion

## Install and configure

1. Install the app from the DMG and drag **Presentation Mode** into Applications.
2. Control-click the app, choose **Open**, and confirm the first-launch prompt. Local builds are ad-hoc signed and are not notarized.
3. Allow Local Network access when requested.
4. Enable the app in **System Settings → Privacy & Security → Screen & System Audio Recording**, then quit and reopen it.
5. Connect and arrange the presentation display as an extended desktop in macOS Display settings.
6. Open Presentation Mode from the menu bar and select that display.
7. Select only the active DeckLink endpoints intended for this room.
8. Enable NDI only when needed and enter the exact source name expected by the receiver. The default is `<Mac name> - NDI 1`.
9. Optionally add the app under **System Settings → General → Login Items & Extensions**.

## Operator workflow

1. Quit ProPresenter or confirm it is not using the outputs.
2. Choose **Canva Mode**.
3. Move the Chrome/Canva window onto the selected extended display.
4. Confirm the picture on every selected SDI destination and, if enabled, the NDI receiver.
5. Choose **Production Mode** before opening ProPresenter. The app stops playback, disables output, and releases every DeckLink device.

Presentation Mode blocks Canva Mode while ProPresenter is running. This prevents the two applications from competing for the same hardware.

## Companion control

The app advertises `_presentation-mode._tcp` with Bonjour and exposes its local HTTP control API on TCP port `9876`. The separately maintained [Presentation Mode Companion Module](https://github.com/DorseyPortfolio/presentation-mode-companion-module) can discover multiple Macs, switch one or all of them between modes, and report mode, ProPresenter, and NDI state.

Allow multicast DNS (UDP 5353) and TCP 9876 between Companion and the Presentation Mode Macs. Routed networks that do not forward Bonjour can use the module's manual-host fallback.

## Build from source

The package contains the Swift/AppKit app, a C++ DeckLink bridge, an NDI bridge, and a hardware discovery probe.

```sh
mkdir -p .build/ModuleCache .build/SwiftPMCache .build/SwiftPMConfig .build/SwiftPMSecurity
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
swift build --disable-sandbox \
  --cache-path "$PWD/.build/SwiftPMCache" \
  --config-path "$PWD/.build/SwiftPMConfig" \
  --security-path "$PWD/.build/SwiftPMSecurity"
```

Run the app or discovery probe:

```sh
swift run PresentationMode
.build/debug/DeckLinkProbe
```

Build an ad-hoc-signed application bundle and installer:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Packaging/build-app.sh
Packaging/create-installer.sh \
  "dist/Presentation Mode.app" \
  "dist/Presentation-Mode-Installer.dmg"
```

After mounting an installer, verify the bundled app:

```sh
codesign --verify --deep --strict \
  "/Volumes/Presentation Mode Installer/Presentation Mode.app"
```

## Architecture

- `Sources/PresentationMode` — AppKit UI, mode controller, display capture, Companion API, and NDI service
- `Sources/DeckLinkBridge` — DeckLink discovery, format validation, BGRA/YUV conversion, scheduled playback, and device release
- `Sources/NDIBridge` — dynamically loaded NDI sender bridge
- `Sources/DeckLinkProbe` — command-line hardware discovery and validation tool
- `Packaging` — app bundle and DMG scripts, icons, NDI runtime, and license notices
- `HardwareSnapshots` and `machine-snapshots` (local and Git-ignored) — machine-specific diagnostics; never publish or apply another Mac's saved profile blindly

DeckLink output runs at 1080p59.94. Native BGRA endpoints use the direct path; compatible Duo 2 endpoints can use Blackmagic's 8-bit YUV conversion path. Scheduled playback uses a bounded queue and fans the same captured frame to each selected output.

## Troubleshooting

- **No displays listed:** grant Screen Recording permission, quit the app completely, and reopen it.
- **No DeckLink endpoints listed:** confirm Desktop Video is installed, the card appears in Desktop Video Setup, and the current profile exposes active playback subdevices. Run `DeckLinkProbe` outside a restrictive sandbox.
- **Canva Mode is unavailable:** quit ProPresenter; the app intentionally yields hardware while it is running.
- **No Companion discovery:** check UDP 5353, TCP 9876, VLAN/multicast rules, and macOS Local Network permission. Use the module's manual host on routed networks.
- **NDI source is missing:** confirm NDI is enabled and its saved source name exactly matches what the receiver expects.
- **Permissions returned after rebuilding:** ad-hoc signatures can cause macOS to treat a rebuilt bundle as a new app; grant Screen Recording again.

## Validation status

The code builds successfully and DeckLink discovery has been validated on active DeckLink 8K Pro endpoints. Before treating a room deployment as complete, physically verify SDI on every selected output, NDI where enabled, repeated Canva/Production transitions, app restart recovery, and immediate ProPresenter device reclaim. The Duo 2 YUV path also requires sustained on-hardware color, cadence, scaling, and frame-lifetime testing.

See [CONTINUE_DEVELOPMENT_ON_ANOTHER_MAC.md](CONTINUE_DEVELOPMENT_ON_ANOTHER_MAC.md) for the current engineering handoff and [DEPLOYMENT.md](DEPLOYMENT.md) for deployment notes.
