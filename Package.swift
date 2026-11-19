// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GridWorld",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "GridWorld", targets: ["GridWorld"])],
    targets: [
        .executableTarget(name: "GridWorld"),
        .testTarget(name: "GridWorldTests", dependencies: ["GridWorld"]),
    ]
)
