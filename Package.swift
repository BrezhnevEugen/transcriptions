// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VoiceTray",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VoiceTray", targets: ["VoiceTray"])
    ],
    targets: [
        .executableTarget(
            name: "VoiceTray",
            path: "VoiceTray",
            exclude: [
                "Info.plist",
                "VoiceTray.entitlements"
            ]
        )
    ]
)
