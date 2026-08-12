# Presentation Mode — DeckLink Mac handoff

## Objective

Finish and test this native macOS app on the Mac that contains the Blackmagic DeckLink Duo 2 or Quad/Quad 2 card.

The operator workflow must remain:

1. Press **CANVA MODE**.
2. Drag a normal Chrome/Canva window to the extended desktop created by an HDMI EDID emulator.
3. Mirror that entire desktop to all selected DeckLink SDI outputs.
4. Press **PRODUCTION MODE** to stop playback and fully release the DeckLink devices for other production software.

No OBS configuration should be required. Room settings must persist across app restarts.

## Current implementation

- Native Swift/AppKit application.
- Display discovery and saved display selection.
- ScreenCaptureKit capture configured for 1920×1080 at 59.94 fps.
- Persistent selected-output settings.
- Canva Mode / Production Mode state controller.
- DeckLink implementation isolated in `Sources/PresentationMode/DeckLinkService.swift`.
- Project builds with Swift 6.1 on macOS.

The current `DeckLinkService` is deliberately a safe stub because the development Mac did not contain Blackmagic Desktop Video, the SDK, or DeckLink hardware. It does not emit SDI yet.

## Instructions for Codex on the DeckLink Mac

1. Read this document and `README.md` completely.
2. Inspect the installed Blackmagic Desktop Video version, DeckLink model, connector mapping, SDK headers, and installed runtime. Do not assume port numbering.
3. If the matching Desktop Video SDK is not present, ask the user to install/download it from Blackmagic Design. Do not substitute an unrelated SDK version silently.
4. Integrate the official macOS DeckLink SDK into this Swift package. A small Objective-C++/C++ bridge target is acceptable and likely preferable to exposing the COM-style SDK directly to Swift.
5. Implement:
   - real device discovery and stable names;
   - validation of 1080p59.94 support;
   - conversion of captured BGRA frames to a DeckLink-supported pixel format;
   - scheduled video playback with a bounded frame queue;
   - identical synchronized fan-out to every selected output;
   - optional embedded stereo audio if ScreenCaptureKit audio is routed through the bridge;
   - clean stop/disable/release behavior;
   - device-arrival/removal recovery and useful status errors.
6. Replace the numbered placeholder checkboxes with discovered device names while preserving saved selection using stable device identifiers.
7. Verify that Production Mode releases every output so the room’s normal production application can immediately claim it.
8. Add a signed `.app` packaging path, Screen Recording usage description, and Login Item support only after core playback works.
9. Test with actual SDI monitors or a waveform monitor. Confirm format, cadence, scaling, audio, restart recovery, and repeated Canva/Production switching.

## Suggested prompt to paste into Codex

> Open this PresentationMode project and read HANDOFF_TO_CODEX.md and README.md completely. This Mac has the actual DeckLink hardware. Inspect the installed Blackmagic Desktop Video runtime, SDK, card model, and connector mapping; then implement and hardware-test the real DeckLinkService bridge. Preserve the one-button Canva Mode / Production Mode workflow. Do not claim completion until video is visible on every selected SDI output and Production Mode reliably releases all devices.

## Build

```sh
swift build
swift run PresentationMode
```

The first capture attempt requires macOS Screen Recording permission and an app restart.
