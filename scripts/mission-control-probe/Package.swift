// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MissionControlProbe",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "MissionControlProbe", path: "Sources"),
        .testTarget(name: "MissionControlProbeTests", dependencies: ["MissionControlProbe"], path: "Tests")
    ]
)
