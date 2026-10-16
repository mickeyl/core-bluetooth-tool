// swift-tools-version:5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "core-bluetooth-tool",
    platforms: [
        .macOS("13"),
        .iOS("16"),
    ],
    products: [
        .executable(name: "core-bluetooth-tool", targets: ["core-bluetooth-tool"]),
        .library(name: "L2CAPBenchKit", targets: ["L2CAPBenchKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", "1.2.2"..<"1.6.0"),
        .package(url: "https://github.com/mxcl/Chalk", .upToNextMajor(from: "0.5.0")),
        .package(url: "https://github.com/Cornucopia-Swift/CornucopiaStreams", branch: "master"),
        //.package(path: "../CornucopiaStreams")
    ],
    targets: [
        .target(name: "L2CAPBenchKit"),
        .executableTarget(
            name: "core-bluetooth-tool",
            dependencies: [
                "L2CAPBenchKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Chalk", package: "Chalk"),
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
        .testTarget(name: "L2CAPBenchKitTests", dependencies: ["L2CAPBenchKit"]),
    ]
)
