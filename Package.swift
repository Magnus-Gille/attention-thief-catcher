// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "attention-thief-catcher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "attention-thief-catcher",
            targets: ["AttentionThiefCatcher"]
        )
    ],
    targets: [
        .executableTarget(
            name: "AttentionThiefCatcher",
            path: "Sources",
            sources: ["attention-thief-catcher.swift"],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        )
    ]
)
