// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "YouTubeScreenshotter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "YouTubeScreenshotter",
            path: "Sources"
        )
    ]
)
