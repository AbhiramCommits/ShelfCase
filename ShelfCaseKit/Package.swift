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
    ],
    targets: [
        .target(
            name: "ShelfCaseKit",
            path: "Sources/ShelfCaseKit"
        ),
        .testTarget(
            name: "ShelfCaseKitTests",
            dependencies: ["ShelfCaseKit"],
            path: "Tests/ShelfCaseKitTests"
        ),
    ]
)
