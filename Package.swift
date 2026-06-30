// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Stratus",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Stratus", targets: ["Stratus"]),
        .library(name: "StratusCore", targets: ["StratusCore"]),
        .executable(name: "StratusFileProviderExtension", targets: ["StratusFileProviderExtension"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0"),
        .package(url: "https://github.com/orlandos-nl/Citadel", from: "0.12.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.15.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "Stratus",
            dependencies: [
                "StratusCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: ".",
            sources: [
                "App",
                "DesignSystem",
                "Features",
            ],
            resources: [
                .process("Resources"),
                .copy("shared"),
            ],
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),
        .target(
            name: "StratusCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Citadel", package: "Citadel"),
            ],
            path: "Core",
            resources: [
                .copy("Persistence/Migrations"),
            ],
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),
        .executableTarget(
            name: "StratusFileProviderExtension",
            dependencies: ["StratusCore"],
            path: "FileProviderExtension",
            exclude: ["Info.plist"],
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),
        .testTarget(
            name: "StratusCoreTests",
            dependencies: [
                "StratusCore",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "Tests",
            sources: [
                "StratusCoreTests",
                "Unit",
                "Integration",
                "Performance",
                "UI",
            ],
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),
    ]
)
