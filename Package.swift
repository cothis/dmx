// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dmx",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "dmx", targets: ["dmx"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "DMXCore"),
        .executableTarget(
            name: "dmx",
            dependencies: [
                "DMXCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "DMXCoreTests", dependencies: ["DMXCore"]),
    ]
)
