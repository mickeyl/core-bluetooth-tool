// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "core-bluetooth-tool",
    platforms: [
        .macOS("10.15.4")
    ],
    products: [
        .executable(name: "core-bluetooth-tool", targets: ["core-bluetooth-tool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", .upToNextMajor(from: "0.4.1")),
        .package(url: "https://github.com/Cornucopia-Swift/CornucopiaStreams.git", .branch("master")),
    ],
    targets: [
        .target(
            name: "core-bluetooth-tool",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "CornucopiaStreams", package: "CornucopiaStreams"),
                ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "./Supporting/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "core-bluetooth-toolTests",
            dependencies: ["core-bluetooth-tool"]),
    ]
)
