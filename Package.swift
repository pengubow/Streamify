// swift-tools-version: 6.0

import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let localBinaryDepsRoot = packageRoot.appendingPathComponent(".build/streamify-deps")
let localMPVKitPath = localBinaryDepsRoot.appendingPathComponent("MPVKit").path
let hasLocalMPVKit = FileManager.default.fileExists(atPath: "\(localMPVKitPath)/Package.swift")

let dependencies: [Package.Dependency] = [
    hasLocalMPVKit
        ? .package(path: localMPVKitPath)
        : .package(url: "https://github.com/edde746/MPVKit.git", revision: "48fa1a1533062ae800772071a0ef6c36f553ba45"),
]

let streamifyDependencies: [Target.Dependency] = [
    .product(name: "MPVKit", package: "MPVKit"),
]

let package = Package(
    name: "Streamify",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "Streamify",
            targets: ["Streamify"]
        ),
    ],
    dependencies: dependencies,
    targets: [
        .target(
            name: "Streamify",
            dependencies: streamifyDependencies
        ),
    ],
    swiftLanguageModes: [.v5]
)
