# Room Setup preview — 0.5.0 build 11

This is an isolated review candidate, not a deployment. The accepted Largo installation remains 0.4.5/build 10.

Controls is the default tab. Setup contains named room profiles and destinations. Each destination chooses Direct/unkeyed or Fill + Key, picture and optional key endpoints, and one of eight progressive 1920×1080 timings: 23.98, 24, 25, 29.97, 30, 50, 59.94 or 60 Hz. Both endpoints of a pair use the same timing and must support synchronized playback on the same physical card.

Edits remain drafts. Validate lists missing/inactive endpoints, collisions, unsupported modes and incompatible pairs. Refresh devices enumerates capabilities without enabling outputs. Endpoint tooltips list supported timings. Apply refreshes capabilities, validates, copies the route into the stopped native session, then saves the library. Revert discards the draft. Both Apply and Revert refuse while outputs or a transition are active. No password or access-control mechanism is added.

Opaque desktop is the supported matte behavior: picture alpha is forced opaque, paired key is white while active and black on stop, then outputs are released and prior playback groups restored. Direct outputs do not send a separate matte. Transparency, interlace and non-1080 resolutions are outside this preview.

## Architecture

RoomProfiles.swift owns schema, default profile, timings and validation. SetupView.swift owns the draft editor. AppController applies profiles only while stopped; DeckLinkService checks device capabilities; DeckLinkBridge copies routes into owned storage and rechecks capabilities before enabling hardware. PlayoutCore schedules any validated direct/pair group at its own cadence. The original Largo topology is now a default fixture, not scheduler logic.

The accepted fix needed structural changes: actual separate fill/key frames, independent group cadences, synchronized starts and key-clear cleanup. Routine card assignments and supported timing changes now use configuration. New resolutions/pixel formats still require implementation and validation.

## Persistence and migration

roomProfiles.v1 stores schema version, active profile and named profiles as Codable JSON in the app's preferences. No previous route schema existed in 0.4.5; its fixed Largo route is the migration default, including direct Confidence. Legacy roomConfiguration.v1 and Companion identity remain separate. The preview uses com.wcmedia.PresentationMode.SettingsPreview, so it does not read or overwrite the installed production preferences. This preview starts with its own NDI/automation defaults disabled. A future production release must retain com.wcmedia.PresentationMode.NDI and test migration with backed-up production preferences; do not copy preview preferences wholesale into production.

Malformed or unknown profile schemas are preserved and block start. Applying a corrected profile explicitly replaces the saved library. Capability validation applies to the selected active room; inactive room profiles can refer to devices on other Macs.

## Build and test

Run `sh Tests/Offline/run.sh`, then `sh Packaging/build-app.sh` on macOS with Xcode tools. Packaging creates `dist/Presentation Mode Settings Preview.app`, version 0.5.0/build 11, with an ad-hoc signature unless CODE_SIGN_IDENTITY is provided. Production packaging is intentionally refused in this preview. Build optimization says “production” in SwiftPM logs; that is release optimization, not the production policy. Default hardware and Companion gates remain off; no outputs start merely by opening it.

Offline verification covers the accepted mixed-cadence route, all eight timings, direct/mixed/16-destination layouts, invalid routes, failure cleanup, unarmed native reconfiguration/lifecycles, profile migration/roundtrip/corruption and build policies. No real device discovery or output calls occur in these tests. The app was built, signature-verified and reviewed locally with hardware disabled and isolated preferences. Controls opens by default; Setup layout, direct/key selection, device validation, invalid-draft errors, Revert and stopped Apply passed. UI review found and fixed top alignment of the destination list and a generic validation error. The accepted Largo profile was saved only in the preview domain, and the preview was stopped after review. Hardware validation remains deferred.

## Release boundary

Review this candidate on an idle machine first. Do not install over accepted 0.4.5 or launch armed while another app owns the outputs. No fleet update is needed merely because Largo required fill/key. A general release should retain per-room configuration and ship only after UI, migration and scheduled hardware validation. Existing Companion 1.2.0 protocol behavior is retained; live Companion testing was not repeated for this preview.

## Controls simplification and flexible rooms

Controls now displays “Room profile loaded” and the dynamic active room name. Routing summaries and explanatory technical subtext were removed. Missing/failed profile load gets an honest no-profile prompt; details stay in Setup. UI test renamed the applied preview profile and verified Controls followed it, then restored Largo Pro1. New room creates an empty profile, with no inherited Largo assignments. Destination names, endpoints and timings are profile data. Generic Setup notes are in SETUP-NOTES.md.

Latest UI review confirmed New room and Add destination in the visible preview. Computer-use transport closed during a subsequent draft rename/validate operation; that operation is uncertain. No Apply was requested for the new room test, so saved Largo remains active. Preview was left open for Joseph and may show the unsaved New room draft; use Revert draft to return to the applied profile. Hardware remains disabled.
