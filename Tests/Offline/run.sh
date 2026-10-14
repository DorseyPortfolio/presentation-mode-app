#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
mkdir -p .build/offline
clang++ -std=c++17 -fsanitize=address,undefined -g -I Sources/DeckLinkBridge Tests/Offline/PlayoutCoreTests.cpp -o .build/offline/playout-tests
.build/offline/playout-tests
clang++ -std=c++17 -fsanitize=address,undefined -g -I Sources/DeckLinkBridge/include -I Sources/DeckLinkBridge/SDK Tests/Offline/UnarmedBridgeTests.cpp Sources/DeckLinkBridge/DeckLinkBridge.cpp Sources/DeckLinkBridge/SDK/DeckLinkAPIDispatch.cpp -framework CoreFoundation -framework CoreVideo -o .build/offline/unarmed-tests
.build/offline/unarmed-tests
swiftc -module-cache-path .build/module-cache Sources/PresentationMode/BuildPolicy.swift Tests/Offline/BuildPolicyTests.swift -o .build/offline/validation-policy-tests
.build/offline/validation-policy-tests
swiftc -D PRESENTATION_MODE_PRODUCTION -module-cache-path .build/module-cache Sources/PresentationMode/BuildPolicy.swift Tests/Offline/BuildPolicyTests.swift -o .build/offline/production-policy-tests
.build/offline/production-policy-tests

swiftc -module-cache-path .build/module-cache Sources/PresentationMode/RoomProfiles.swift Tests/Offline/RoomProfileTests.swift -o .build/offline/room-profile-tests
.build/offline/room-profile-tests
