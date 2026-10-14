// swift-tools-version: 6.0
import PackageDescription
import Foundation

let production = ProcessInfo.processInfo.environment["PRESENTATION_MODE_BUILD_FLAVOR"] == "production"

let package = Package(
    name: "PresentationMode",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PresentationMode", targets: ["PresentationMode"]),
        .executable(name: "DeckLinkProbe", targets: ["DeckLinkProbe"])
    ],
    targets: [
        .target(
            name: "DeckLinkBridge",
            path: "Sources/DeckLinkBridge",
            publicHeadersPath: "include",
            cxxSettings: [.headerSearchPath("SDK")] + (production ? [.define("PM_PRODUCTION_BUILD")] : []),
            linkerSettings: [.linkedFramework("CoreFoundation"), .linkedFramework("CoreVideo")]
        ),
        .target(
            name: "NDIBridge",
            path: "Sources/NDIBridge",
            publicHeadersPath: "include",
            cxxSettings: [.headerSearchPath("SDK")],
            linkerSettings: [.linkedFramework("CoreVideo"), .linkedLibrary("dl")]
        ),
        .executableTarget(
            name: "DeckLinkProbe",
            dependencies: ["DeckLinkBridge"]
        ),
        .executableTarget(
            name: "PresentationMode",
            dependencies: ["DeckLinkBridge", "NDIBridge"],
            swiftSettings: production ? [.define("PRESENTATION_MODE_PRODUCTION")] : [],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Network")
            ]
        )
    ]
)
