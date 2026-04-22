// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PushToTalk",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PushToTalk",
            path: "Sources/PushToTalk"
        )
    ]
)
