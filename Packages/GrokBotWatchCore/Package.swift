// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GrokBotWatchCore",
    platforms: [.iOS("26.0"), .watchOS("26.0")],
    products: [.library(name: "GrokBotWatchCore", targets: ["GrokBotWatchCore"])],
    targets: [
        .target(name: "GrokBotWatchCore"),
        .testTarget(name: "GrokBotWatchCoreTests", dependencies: ["GrokBotWatchCore"]),
    ]
)
