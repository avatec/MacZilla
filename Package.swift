// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacZilla",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacZilla", targets: ["MacZilla"]),
        .library(name: "MacZillaCore", targets: ["MacZillaCore"]),
    ],
    targets: [
        .target(name: "MacZillaCore"),
        .executableTarget(name: "MacZilla", dependencies: ["MacZillaCore"]),
        .testTarget(name: "MacZillaCoreTests", dependencies: ["MacZillaCore"]),
    ]
)
