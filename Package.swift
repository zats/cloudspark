// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CloudflareKit",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "CloudflareKit",
            targets: ["CloudflareKit"]
        ),
        .executable(
            name: "cloudflare",
            targets: ["cloudflare"]
        ),
        .executable(
            name: "cloudflare2",
            targets: ["cloudflare2"]
        ),
        .executable(
            name: "cloudflare2ctl",
            targets: ["cloudflare2ctl"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "CloudflareKit"
        ),
        .executableTarget(
            name: "cloudflare",
            dependencies: [
                "CloudflareKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "cloudflare2",
            dependencies: []
        ),
        .executableTarget(
            name: "cloudflare2ctl",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "CloudflareKitTests",
            dependencies: ["CloudflareKit"]
        ),
    ]
)
