// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Autohop",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AutohopCore",
            targets: ["AutohopCore"]
        ),
        .executable(
            name: "RSSParserSmoke",
            targets: ["RSSParserSmoke"]
        ),
        .executable(
            name: "OPMLSmoke",
            targets: ["OPMLSmoke"]
        ),
        .executable(
            name: "SubscriptionStoreSmoke",
            targets: ["SubscriptionStoreSmoke"]
        ),
        .executable(
            name: "DownloadManagerSmoke",
            targets: ["DownloadManagerSmoke"]
        )
    ],
    targets: [
        .target(
            name: "AutohopCore",
            path: ".",
            exclude: [
                "App",
                "Chapters",
                "Feeds/FeedPreviewViewModel.swift",
                "Feeds/FeedService.swift",
                "OPMLSmokeTests",
                "Persistence/SettingsStore.swift",
                "Playback",
                "Queue",
                "README.md",
                "Settings",
                "SmokeTests",
                "SubscriptionStoreSmokeTests",
                "DownloadManagerSmokeTests",
                "Tests",
                "Views"
            ],
            sources: [
                "Models/Chapter.swift",
                "Models/Subscription.swift",
                "Models/Episode.swift",
                "Models/AppSettings.swift",
                "Models/PlaybackPreference.swift",
                "Feeds/ParsedFeed.swift",
                "Feeds/RSSParser.swift",
                "Feeds/OPMLService.swift",
                "Persistence/SubscriptionStore.swift",
                "Downloads/DownloadManager.swift"
            ]
        ),
        .executableTarget(
            name: "RSSParserSmoke",
            dependencies: ["AutohopCore"],
            path: "SmokeTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
        .executableTarget(
            name: "OPMLSmoke",
            dependencies: ["AutohopCore"],
            path: "OPMLSmokeTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
        .executableTarget(
            name: "SubscriptionStoreSmoke",
            dependencies: ["AutohopCore"],
            path: "SubscriptionStoreSmokeTests"
        ),
        .executableTarget(
            name: "DownloadManagerSmoke",
            dependencies: ["AutohopCore"],
            path: "DownloadManagerSmokeTests"
        ),
        .testTarget(
            name: "AutohopCoreTests",
            dependencies: ["AutohopCore"],
            path: "Tests",
            exclude: [
                "RSSParserSmokeTest.swift"
            ],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
