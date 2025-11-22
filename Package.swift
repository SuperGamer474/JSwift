// swift-tools-version:5.6
import PackageDescription

let package = Package(
    name: "ApplePye",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(name: "ApplePye", targets: ["ApplePye"])
    ],
    targets: [
        .target(
            name: "ApplePye",
            path: "Sources/ApplePye"
        )
    ]
)
