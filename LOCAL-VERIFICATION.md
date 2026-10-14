# Current local verification — build 12

Build 12 source commit fd492cc removes Swift and native runtime arming requirements. The app opens normally with outputs stopped; Canva Mode starts hardware. Offline bridge tests now compile with PM_OFFLINE_TEST_BUILD and cannot claim hardware. Companion policy is unchanged.

PASS: release build and strict deep signature verification. Full offline suite: 46 scheduler/pixel cases under ASan/UBSan, 20 hardware-disabled native lifecycle/reconfiguration cycles, validation/production network policies, profile migration/persistence/corruption checks and four-card hardware-model cases. Build 12 logs are offline-tests.txt and build.txt in the handoff package.

PASS: installed build 12 executable matches the built artifact; ordinary open through LaunchServices produced a running process without the developer command. Saved configuration/profile values compare equal after decoding (serialized JSON key order changed). Build 11 app/preferences were backed up before replacement. Accepted 0.4.5 rollback remains intact. No outputs were started by the agent in the build 12 update or this handoff refresh.

Earlier build 11 stopped-output UI checks remain relevant because the layout/profile logic was not changed: Direct releases Key; Fill+Key uses selected Fill; eligible common-mode Key selector; Revert/Apply/persistence; approved two-pane layout. Read-only SDK discovery found two DeckLink 8K Pro cards, four logical outputs each and 58 supported SDI modes per output. Four physical cards remain untested.

PENDING: Joseph’s physical LED-wall, side-screen and confidence-screen verification of build 12. Earlier acceptance of the fixed Largo app is not acceptance of this generalized candidate. No transfer, push or duplicate live test was performed. Publish from ProductionMac after testing/release review and authorization.
