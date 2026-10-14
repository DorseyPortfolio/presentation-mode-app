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

Offline verification covers the accepted mixed-cadence route, all eight timings, direct/mixed/16-destination layouts, invalid routes, failure cleanup, unarmed native reconfiguration/lifecycles, profile migration/roundtrip/corruption and build policies. No real device discovery or output calls occur in these tests. The app was built and signature-verified but not launched for UI or hardware review while Joseph worked in ProPresenter. Those checks remain pending.

## Release boundary

Review this candidate on an idle machine first. Do not install over accepted 0.4.5 or launch armed while another app owns the outputs. No fleet update is needed merely because Largo required fill/key. A general release should retain per-room configuration and ship only after UI, migration and scheduled hardware validation. Existing Companion 1.2.0 protocol behavior is retained; live Companion testing was not repeated for this preview.
