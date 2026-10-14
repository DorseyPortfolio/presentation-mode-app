> Historical record from an earlier version. Commands, package contents and validation claims below describe that checkpoint. For 0.5.0/build 12, use [README.md](README.md) and [PUBLICATION-VERIFICATION.md](PUBLICATION-VERIFICATION.md).

# Presentation Mode — continuation handoff (2026-08-12)

## Start here

This package is the current editable source and deployment state for **Presentation Mode 0.4.2 (build 7)**. Copy the package to the other Mac, extract it, and give this Markdown file to the next development chat.

Suggested opening prompt:

> Continue development of Presentation Mode from this handoff. Read `CONTINUE_DEVELOPMENT_ON_ANOTHER_MAC.md`, `PresentationMode-DeckLink/README.md`, and `PresentationMode-DeckLink/HANDOFF_TO_CODEX.md` completely. Preserve each Mac's existing Blackmagic Desktop Video card profile. Do not claim hardware completion until SDI is visible on every selected output, the configured NDI receiver works where enabled, and Production Mode reliably releases the devices for ProPresenter.

## Current implementation

- Native Swift/AppKit macOS application.
- ScreenCaptureKit display capture.
- DeckLink scheduled BGRA playback at 1080p59.94.
- DeckLink Duo 2 fallback playback through BGRA-to-8-bit-YUV conversion when BGRA is not a native output format.
- Persistent selection by DeckLink persistent ID and subdevice index.
- Automatic Production Mode while ProPresenter is running.
- Bitfocus Companion HTTP/Bonjour API on TCP port 9876.
- Optional NDI sender with per-Mac enabled state and saved source name.
- Ad-hoc signed app and a verified compressed DMG installer.

## Changes made on Largo Pro 2

DeckLink discovery originally used only Desktop Video 16.0 interface IDs. Largo Pro 2 runs Desktop Video **15.3.1**, whose `IDeckLinkProfileAttributes` and `IDeckLinkOutput` interfaces have older IIDs. That caused enumeration to return devices without readable playback/profile attributes, so the Swift layer filtered every endpoint out.

`Sources/DeckLinkBridge/DeckLinkBridge.cpp` now:

- falls back to `IID_IDeckLinkProfileAttributes_v15_3_1` when the 16.0 attributes interface is unavailable;
- uses `IID_IDeckLinkOutput_v15_3_1` for mode validation and playback, which Desktop Video 16 retains for backward compatibility;
- validates the output explicitly as SDI;
- does not activate or change a DeckLink profile.

The Swift-built hardware probe on Largo Pro 2 returned eight DeckLink 8K Pro subdevices. Three were active and all three validated for 1080p59.94 BGRA:

```text
000000000182b950:0 | DeckLink 8K Pro (1) | playback=true active=true 1080p59.94-bgra=true
000000000182b951:1 | DeckLink 8K Pro (2) | playback=true active=true 1080p59.94-bgra=true
00000000828eb5c0:0 | DeckLink 8K Pro (1) | playback=true active=true 1080p59.94-bgra=true
```

The other five enumerated subdevices were inactive under the existing production profiles. Do not change those profiles merely to expose more endpoints.

## DeckLink Duo 2 support added in 0.4.2

Some Duo 2 configurations support 1080p59.94 SDI timing but do not accept captured BGRA as a native output pixel format. Version 0.4.2 changes `DeckLinkBridge.cpp` so discovery accepts an active endpoint when it supports either native 8-bit BGRA or 8-bit YUV at 1080p59.94.

At session start, each endpoint records whether it needs conversion. When required, the bridge:

1. wraps the captured CVPixelBuffer as the original BGRA DeckLink frame;
2. creates a 1920×1080, 8-bit YUV destination frame;
3. converts with Blackmagic's `IDeckLinkVideoConversion` API;
4. schedules the converted frame through the same bounded playback queue;
5. releases the converter and all frames when Production Mode stops the session.

Native-BGRA outputs keep the original zero-conversion path. This change compiled successfully and did not regress discovery of the three active 8K Pro endpoints on Largo Pro 2. The Duo 2 conversion path has not been physically validated on this Mac because no Duo 2 is installed here; confirm visible SDI output and repeated release/reclaim behavior on the Duo-equipped Mac.

## NDI behavior

NDI is now optional per installation:

- Largo Pro 2 defaults to enabled with sender name **`Largo Pro 2 - NDI 1`**.
- The sender name is editable so it can exactly match the corresponding ProPresenter source identity.
- A Mac without an NDI output can disable NDI in the app; DeckLink operation continues normally.
- Companion's API schema did not change. Disabled NDI reports `ndiRunning: false` and an empty `ndiSource`, so Companion module 1.1.0 remains compatible.

The exact receiver-side NDI name and visible video still need confirmation in the room. If ProPresenter advertises a different exact sender name, enter that name in Presentation Mode.

## Build environment

Tested on:

- Mac Studio `Mac15,14`, Apple M3 Ultra
- macOS 26.3.1
- Xcode 26.6
- Blackmagic Desktop Video 15.3.1
- DeckLink API framework containing arm64 and x86_64

Build:

```sh
cd PresentationMode-DeckLink
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Packaging/build-app.sh
```

Run the discovery probe:

```sh
cd PresentationMode-DeckLink
mkdir -p .build/ModuleCache .build/SwiftPMCache .build/SwiftPMConfig .build/SwiftPMSecurity
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift build --disable-sandbox \
  --cache-path "$PWD/.build/SwiftPMCache" \
  --config-path "$PWD/.build/SwiftPMConfig" \
  --security-path "$PWD/.build/SwiftPMSecurity" \
  --product DeckLinkProbe
.build/debug/DeckLinkProbe
```

The probe must run with normal hardware/XPC access; a restrictive sandbox can make Blackmagic's XPC connection fail even when the driver is healthy.

Create the installer:

```sh
cd PresentationMode-DeckLink
Packaging/create-installer.sh \
  "dist/Presentation Mode.app" \
  "dist/Presentation-Mode-0.4.2-build-7-Installer.dmg"
```

Use the standard compressed DMG path. The script's hybrid-HFS fallback can attach Finder metadata to `libndi.dylib` and invalidate strict signature verification. Always mount the finished DMG and run:

```sh
codesign --verify --deep --strict "/Volumes/Presentation Mode Installer/Presentation Mode.app"
```

## Artifacts in this package

- `PresentationMode-DeckLink/` — editable Swift/C++ source, SDK headers, packaging assets, and hardware snapshots.
- `companion-module-presentation-mode/` — Companion module 1.1.0 source; no update was required for app 0.4.2.
- `artifacts/Presentation Mode 0.4.2.app.zip` — transferable built app.
- `artifacts/Presentation-Mode-0.4.2-build-7-Installer.dmg` — verified installer.
- `machine-snapshots/largo-pro-2-2026-08-12/` — this Mac's saved Desktop Video settings and summary.
- `SHA256SUMS.txt` — integrity checks for the handoff contents.

## Required remaining tests

1. With ProPresenter running, confirm Presentation Mode remains in Production Mode and does not claim outputs.
2. Quit ProPresenter and enter Canva Mode.
3. Confirm the intended display appears physically on every selected SDI destination.
4. Where NDI is enabled, confirm the configured receiver sees the exact expected source and live video.
5. Enter Production Mode and immediately confirm ProPresenter can reclaim every DeckLink output and the NDI identity.
6. Repeat the Canva/Production transition several times and after an app restart.
7. On a Duo 2 endpoint, verify the YUV conversion path has correct color, cadence, scaling, and frame lifetime under sustained playback.

Do not describe the system as fully fixed until those physical tests pass.
