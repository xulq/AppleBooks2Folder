// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppleBooks2Folder",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ZIPFoundation", path: "Vendor/ZIPFoundation", exclude: ["LICENSE"]),
        .target(name: "AppleBooks2FolderCore", dependencies: ["ZIPFoundation"]),
        .executableTarget(name: "AppleBooks2Folder", dependencies: ["AppleBooks2FolderCore"]),
        .testTarget(name: "AppleBooks2FolderTests", dependencies: ["AppleBooks2FolderCore", "ZIPFoundation"])
    ]
)
