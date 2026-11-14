// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flump",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Flump", targets: ["Flump"])
    ],
    targets: [
        .target(name: "FlumpCore", resources: [.process("PinnedTools.json")]),
        .executableTarget(name: "Flump", dependencies: ["FlumpCore"]),
        .testTarget(name: "FlumpCoreTests", dependencies: ["FlumpCore"]),
    ]
)
