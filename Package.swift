// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JSwift",
    platforms: [
        .iOS(.v13), .macCatalyst(.v13)
    ],
    products: [
        .library(
            name: "JSwift",
            targets: ["JSwift"]
        ),
    ],
    targets: [
        .target(
            name: "JSwift",
            dependencies: []
        ),
    ]
)
