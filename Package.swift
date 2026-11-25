// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "scrubshot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "scrubshot", targets: ["scrubshot"]),
        .library(name: "ScrubshotCore", targets: ["ScrubshotCore"]),
    ],
    targets: [
        .target(name: "ScrubshotCore"),
        .executableTarget(name: "scrubshot", dependencies: ["ScrubshotCore"]),
        .testTarget(name: "ScrubshotCoreTests", dependencies: ["ScrubshotCore"]),
        .testTarget(name: "ScrubshotServeTests", dependencies: ["scrubshot", "ScrubshotCore"]),
    ],
    swiftLanguageModes: [.v5]
)
