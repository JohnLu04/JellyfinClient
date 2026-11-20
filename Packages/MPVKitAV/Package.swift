// swift-tools-version:5.9

// Streamyfin's MPVKit build (https://github.com/streamyfin/MPVKit, release 0.41.0-av5): libmpv with
// the AVFoundation video output (vo_avfoundation), which draws into an AVSampleBufferDisplayLayer –
// what Picture in Picture needs, also starting by itself when the app is left. GPL-3.0 build.
// The package in that repository still points at an older binary, so this one names the release
// Streamyfin itself uses.

import PackageDescription

let package = Package(
    name: "MPVKitAV",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "MPVKitAV", targets: ["MPVKitAV"]),
    ],
    targets: [
        .target(
            name: "MPVKitAV",
            dependencies: ["MPVKit"],
            path: "Sources/MPVKitAV",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("VideoToolbox"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("xml2"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
                .linkedLibrary("resolv"),
                .linkedLibrary("expat"),
            ]
        ),
        .binaryTarget(
            name: "MPVKit",
            url: "https://github.com/streamyfin/MPVKit/releases/download/0.41.0-av5/MPVKit.xcframework.zip",
            checksum: "80a79fbb34b1a3ae84744fe7bb9d365d2a006a5f617460933b7ce777251d3618"
        ),
    ]
)
