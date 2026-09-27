// swift-tools-version: 6.0
import PackageDescription

// The same two modules scripts/build.sh produces with plain swiftc. That
// script is the primary build: SwiftPM needs a working Xcode toolchain, and a
// machine with only Command Line Tools may not be able to link the manifest.
let package = Package(
    name: "macOS-computer-control",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacControlKit", targets: ["MacControlKit"]),
        .executable(name: "macctl", targets: ["macctl"]),
    ],
    targets: [
        .target(name: "MacControlKit"),
        .executableTarget(name: "macctl", dependencies: ["MacControlKit"]),
        // Plain-swiftc tests rather than XCTest, so they run where only the
        // compiler is installed: `swift run macctl-tests`, or scripts/test.sh.
        .executableTarget(
            name: "macctl-tests",
            dependencies: ["MacControlKit"],
            path: "Tests/MacControlKitTests"
        ),
    ]
)
