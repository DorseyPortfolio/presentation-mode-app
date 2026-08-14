# Presentation Mode for macOS

Presentation Mode is a native macOS menu-bar app for switching presentation rooms between a simple mirrored desktop workflow and a full ProPresenter production workflow. It captures a dedicated Mac display and sends it to Blackmagic DeckLink SDI outputs and, optionally, NDI—then releases that hardware when it is time for ProPresenter to take over.

It is designed for churches, auditoriums, conference rooms, live-event venues, and broadcast installations where non-technical presenters need to show Canva, Chrome, Keynote, PowerPoint, Zoom, or another desktop app without reconfiguring the production system.

## Why Presentation Mode is useful

Production rooms often have two very different jobs:

1. A normal user needs one presentation image mirrored everywhere.
2. A production operator needs ProPresenter to control multiple independent outputs.

Switching between those jobs manually can mean changing DeckLink ownership, display routing, NDI sources, and hardware settings. Presentation Mode provides a clear **Canva Mode** and **Production Mode** so the room can change workflows without altering saved Blackmagic Desktop Video profiles.

- **Canva Mode** captures one extended Mac display and sends the same image to every selected SDI output. Optional NDI output can feed network receivers.
- **Production Mode** stops capture, disables playback, and releases the DeckLink devices so ProPresenter can claim them.
- **Automatic ProPresenter switching** can move into Production Mode when ProPresenter opens and return to Canva Mode when it closes. Version 0.4.3 makes this behavior optional and persistent.

## Features

- Native Apple silicon macOS application built with Swift and AppKit
- ScreenCaptureKit desktop capture at up to 3840×2160
- Blackmagic DeckLink SDI output with persistent device selection
- Support for compatible DeckLink 8K Pro and DeckLink Duo 2 workflows
- BGRA and 8-bit YUV output paths, including 1080p59.94 playback
- Optional NDI sender with a saved, per-Mac source name
- Automatic or manual switching when ProPresenter opens and closes
- Bonjour discovery and a local HTTP API for Bitfocus Companion
- Multi-Mac control through the companion module
- No automatic changes to DeckLink profiles, connector mappings, or saved Desktop Video settings

## Common use cases

- Let a guest presenter use Canva or a web browser on the room’s existing SDI displays
- Mirror PowerPoint, Keynote, Zoom, or training content across several destinations
- Return DeckLink outputs to ProPresenter without restarting the Mac
- Give a volunteer one-button room switching through Bitfocus Companion
- Control several presentation Macs from a single Companion surface
- Keep an NDI receiver connected to a predictable source name across mode changes

## Requirements

- Apple silicon Mac
- macOS 14 Sonoma or newer
- Blackmagic Desktop Video 15.3.1 or newer
- Compatible Blackmagic DeckLink hardware for SDI output
- A dedicated extended display or HDMI EDID emulator for the presentation desktop
- Optional NDI receiver for network video
- Optional Bitfocus Companion and the [Presentation Mode Companion Module](https://github.com/DorseyPortfolio/presentation-mode-companion-module)

## Install and configure

1. Download the latest installer from the repository’s GitHub Releases page.
2. Drag **Presentation Mode** into Applications.
3. Control-click the app, choose **Open**, and approve the first launch. Current local releases are ad-hoc signed and are not notarized.
4. Allow Local Network access when prompted.
5. Enable **Presentation Mode** under **System Settings → Privacy & Security → Screen & System Audio Recording**, then quit and reopen it.
6. Connect and arrange the presentation display as an extended desktop in macOS Display settings.
7. Select that display and the intended DeckLink outputs in Presentation Mode.
8. Enable NDI only if the room needs it, and enter the exact source name expected by the receiver.
9. Choose whether **Automatically switch when ProPresenter opens or closes** should be enabled.

## Operator workflow

### Canva Mode

1. Choose **Canva Mode** in the menu-bar app or Companion.
2. Move Canva, Chrome, PowerPoint, Keynote, Zoom, or another app onto the selected presentation display.
3. Confirm the mirrored image on the selected SDI and NDI destinations.

When automatic ProPresenter switching is enabled, Canva Mode is blocked while ProPresenter is running to prevent both applications from competing for the same hardware.

### Production Mode

Choose **Production Mode** before using ProPresenter. Presentation Mode immediately stops capture and scheduled playback, disables its outputs, and releases each DeckLink device.

With automatic switching enabled, opening ProPresenter performs this transition automatically. When automation is disabled, the operator retains manual control even while ProPresenter is open.

## Bitfocus Companion control

Presentation Mode advertises `_presentation-mode._tcp` with Bonjour and exposes its local control API on TCP port `9876`. The companion module can discover one or more Macs and provide:

- Canva Mode, Production Mode, and automatic reconciliation actions
- On, Off, and Toggle controls for automatic ProPresenter switching
- Per-device and all-device presets
- Live mode, online, ProPresenter, automation, and NDI feedback
- Aggregate and per-device Companion variables

Allow multicast DNS on UDP 5353 and TCP 9876 between Companion and each Mac. Routed networks that do not forward Bonjour can use the module’s manual-host fallback.

## Build from source

The project contains the Swift/AppKit app, C++ DeckLink bridge, dynamically loaded NDI bridge, and a hardware discovery probe.

```sh
mkdir -p .build/ModuleCache .build/SwiftPMCache .build/SwiftPMConfig .build/SwiftPMSecurity
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
swift build --disable-sandbox \
  --cache-path "$PWD/.build/SwiftPMCache" \
  --config-path "$PWD/.build/SwiftPMConfig" \
  --security-path "$PWD/.build/SwiftPMSecurity"
```

Run the app or DeckLink discovery probe:

```sh
swift run PresentationMode
.build/debug/DeckLinkProbe
```

Build the application bundle and installer:

```sh
./Packaging/build-app.sh
./Packaging/create-installer.sh \
  "dist/Presentation Mode.app" \
  "dist/Presentation-Mode-0.4.3-Installer.dmg"
codesign --verify --deep --strict "dist/Presentation Mode.app"
```

## Architecture

- `Sources/PresentationMode` — AppKit UI, mode controller, display capture, Companion API, and NDI service
- `Sources/DeckLinkBridge` — DeckLink discovery, format validation, frame conversion, scheduled playback, and device release
- `Sources/NDIBridge` — dynamically loaded NDI sender bridge
- `Sources/DeckLinkProbe` — command-line DeckLink discovery and validation utility
- `Packaging` — application bundle and DMG scripts, icons, NDI runtime, and required license notices

The DeckLink bridge uses compatibility interfaces available in Blackmagic Desktop Video 15.3.1 and 16.0. Selected outputs are preserved by persistent hardware ID. The app does not activate subdevices or modify persistent card profiles.

## Troubleshooting

- **No displays listed:** grant Screen Recording permission, quit Presentation Mode completely, and reopen it.
- **No DeckLink endpoints listed:** confirm Desktop Video is installed and that the current card profile exposes active playback subdevices. Run `DeckLinkProbe` outside a restrictive sandbox.
- **Canva Mode is unavailable:** ProPresenter is running while automatic switching is enabled. Quit ProPresenter or disable automatic switching if manual control is intended.
- **No Companion discovery:** check UDP 5353, TCP 9876, VLAN/multicast rules, and macOS Local Network permission. Use a manual host on routed networks.
- **NDI source is missing:** confirm NDI is enabled and that its saved source name exactly matches the receiver configuration.
- **Permissions returned after rebuilding:** macOS may treat an ad-hoc-signed rebuild as a new app; grant Screen Recording permission again.

## Validation status

The source builds successfully and the release artifacts are packaged. Room deployment still requires physical validation with the actual DeckLink outputs, NDI receivers, ProPresenter workflow, reference topology, and sustained video playback. Preserve each Mac’s existing Blackmagic Desktop Video profile during testing.

See [DEPLOYMENT.md](DEPLOYMENT.md) for deployment guidance and [CONTINUE_DEVELOPMENT_ON_ANOTHER_MAC.md](CONTINUE_DEVELOPMENT_ON_ANOTHER_MAC.md) for engineering handoff notes.
