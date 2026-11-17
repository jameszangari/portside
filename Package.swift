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
        // String form: .v26 needs PackageDescription 6.2; tools-version stays 5.10.
        .macOS("26.0")
    ],
    products: [
        .executable(name: "portside", targets: ["portside"]),
        // Loaded into /usr/bin/perl at run time, never linked; see
        // Sources/MediaRemoteAdapter/README.md.
        .library(name: "MediaRemoteAdapter", type: .dynamic, targets: ["MediaRemoteAdapter"])
    ],
    targets: [
        .target(
            name: "MediaRemoteAdapter",
            path: "Sources/MediaRemoteAdapter",
            exclude: ["LICENSE", "README.md"],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src")
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .target(
            name: "AppLoginItemList",
            path: "Sources/AppLoginItemList",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreServices")
            ]
        ),
        .executableTarget(
            name: "portside",
            dependencies: ["AppLoginItemList"],
            path: "Sources/portside",
            resources: [
                .process("Support")
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist])
            ]
        ),
        // Run with CFFIXED_USER_HOME set (see docs/BASELINE_2_0.md): model
        // setters persist to dock.json under the home folder.
        .testTarget(
            name: "portsideTests",
            dependencies: ["portside"],
            path: "Tests/portsideTests",
            exclude: ["Fixtures"]
        )
    ]
)
