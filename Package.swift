// swift-tools-version: 5.10
import Foundation
import PackageDescription

/// Embedded into the executable's __TEXT,__info_plist section. An SPM
/// executable has no app bundle, and privacy prompts (Calendar) require
/// usage-description strings, so the plist has to live in the binary.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Info.plist").path

let package = Package(
    name: "portside",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "portside",
            path: "Sources/portside",
            resources: [
                .process("Support")
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist])
            ]
        )
    ]
)
