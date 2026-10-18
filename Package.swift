// swift-tools-version: 6.0
import PackageDescription

// MusicCore is pure Swift (Foundation only) so it builds and tests on Linux CI.
// The MCP server itself needs CoreMIDI / ApplicationServices and is macOS-only.

var products: [Product] = [
    .library(name: "MusicCore", targets: ["MusicCore"]),
]

var targets: [Target] = [
    .target(
        name: "MusicCore",
        path: "Sources/MusicCore"
    ),
    .testTarget(
        name: "MusicCoreTests",
        dependencies: ["MusicCore"],
        path: "Tests/MusicCoreTests"
    ),
]

var dependencies: [Package.Dependency] = []

#if os(macOS)
products.append(.executable(name: "LogicGrooveMCP", targets: ["LogicGrooveMCP"]))
dependencies.append(.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"))
targets.append(contentsOf: [
    .executableTarget(
        name: "LogicGrooveMCP",
        dependencies: [
            "MusicCore",
            .product(name: "MCP", package: "swift-sdk"),
        ],
        path: "Sources/LogicGrooveMCP",
        linkerSettings: [
            .linkedFramework("CoreMIDI"),
            .linkedFramework("ApplicationServices"),
            .linkedFramework("CoreGraphics"),
        ]
    ),
    .testTarget(
        name: "LogicGrooveMCPTests",
        dependencies: ["LogicGrooveMCP"],
        path: "Tests/LogicGrooveMCPTests"
    ),
])
#endif

let package = Package(
    name: "LogicGrooveMCP",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
