// swift-tools-version:5.10
import PackageDescription

// Sparkle 2.10.0 (auto-updates) is vendored by scripts/fetch-sparkle.sh (checksum-pinned):
// SwiftPM's own artifact download hangs on jaws-mini, and build.sh signs this exact layout.
let package = Package(
    name: "NotchPeek",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(name: "Sparkle", path: "vendor/Sparkle.xcframework"),
        .executableTarget(name: "NotchPeek", dependencies: ["Sparkle"], path: "Sources/NotchPeek"),
    ]
)
