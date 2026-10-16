// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShelfCaseKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ShelfCaseKit", targets: ["ShelfCaseKit"]),
        .executable(name: "ShelfCaseSyncSoak", targets: ["ShelfCaseSyncSoak"]),
    ],
    targets: [
        .target(
            name: "ShelfCaseKit",
            path: "Sources/ShelfCaseKit"
        ),
        // Headless, reproducible harness: drives the real sync engine against an
        // in-process server over a fault-injecting transport, and prints the
        // local-vs-server divergence. Run via scripts/sync-soak.sh.
        .executableTarget(
            name: "ShelfCaseSyncSoak",
            dependencies: ["ShelfCaseKit"],
            path: "Sources/ShelfCaseSyncSoak"
        ),
        .testTarget(
            name: "ShelfCaseKitTests",
            dependencies: ["ShelfCaseKit"],
            path: "Tests/ShelfCaseKitTests"
        ),
    ]
)
