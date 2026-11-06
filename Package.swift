// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppleBooks2Floder",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ZIPFoundation", path: "Vendor/ZIPFoundation", exclude: ["LICENSE"]),
        .target(name: "AppleBooks2FloderCore", dependencies: ["ZIPFoundation"]),
        .executableTarget(name: "AppleBooks2Floder", dependencies: ["AppleBooks2FloderCore"]),
        .testTarget(name: "AppleBooks2FloderTests", dependencies: ["AppleBooks2FloderCore", "ZIPFoundation"])
    ]
)
