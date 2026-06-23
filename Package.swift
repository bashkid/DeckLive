// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeckLive",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "DeckLive",
            path: "Sources/DeckLive",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
