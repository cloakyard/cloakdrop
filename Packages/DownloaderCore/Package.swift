// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DownloaderCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "DownloadModels", targets: ["DownloadModels"]),
        .library(name: "DownloadPersistence", targets: ["DownloadPersistence"]),
        .library(name: "DownloadEngine", targets: ["DownloadEngine"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        // MARK: Models — pure value types, no dependencies.
        .target(
            name: "DownloadModels",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DownloadModelsTests",
            dependencies: ["DownloadModels"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Persistence — GRDB-backed store behind a protocol.
        .target(
            name: "DownloadPersistence",
            dependencies: [
                "DownloadModels",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DownloadPersistenceTests",
            dependencies: ["DownloadPersistence"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Engine — actor-based download engine.
        .target(
            name: "DownloadEngine",
            dependencies: ["DownloadModels", "DownloadPersistence"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DownloadEngineTests",
            dependencies: ["DownloadEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
