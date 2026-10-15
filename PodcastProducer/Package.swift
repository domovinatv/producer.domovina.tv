// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PodcastProducer",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Sparkle: automatsko ažuriranje izvan App Storea. Aplikacija čita
        // appcast.xml s javnog R2 bucketa domovina-studio-releases.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .executableTarget(
            name: "PodcastProducer",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources"
        )
    ]
)
