// swift-tools-version: 6.0
import PackageDescription

// The CLI, including its Simulator Server, builds without the desktop app, Ghostty or XcodeGen.
let package = Package(
    name: "MuxifyCLI",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "muxify", targets: ["MuxifyCLI"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
    ],
    targets: [
        .target(name: "MuxifySimulatorPrivate"),
        .target(name: "MuxifySimulatorServer", dependencies: [
            "MuxifySimulatorPrivate",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
        ], exclude: ["Web"], plugins: ["EmbedWebAssetsPlugin"]),
        .executableTarget(name: "EmbedWebAssets", path: "Tools/EmbedWebAssets"),
        .plugin(name: "EmbedWebAssetsPlugin", capability: .buildTool(), dependencies: ["EmbedWebAssets"]),
        .executableTarget(name: "MuxifyCLI", dependencies: ["MuxifySimulatorServer"]),
        .testTarget(name: "MuxifyCLITests", dependencies: ["MuxifyCLI"]),
        .testTarget(name: "MuxifySimulatorServerTests", dependencies: ["MuxifySimulatorServer"]),
    ],
    swiftLanguageModes: [.v5]
)
