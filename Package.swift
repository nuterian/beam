// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "beam",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BeamCore"),
        .executableTarget(name: "beam", dependencies: ["BeamCore"], path: "Sources/Beam"),
        .executableTarget(name: "bench-tcp-echo", dependencies: ["BeamCore"]),
        .executableTarget(name: "bench-discovery", dependencies: ["BeamCore"]),
        .executableTarget(name: "perf-gate", dependencies: ["BeamCore"]),
        .testTarget(name: "BeamCoreTests", dependencies: ["BeamCore"]),
    ],
    // Language mode 5 while the codebase is AppKit/Metal-callback heavy;
    // strict-concurrency adoption is planned with Phase 1's threading work.
    swiftLanguageVersions: [.v5]
)
