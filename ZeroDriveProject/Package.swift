// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZeroDrive",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ZeroDrive",
            targets: ["ZeroDrive"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "ZeroDrive",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("Charts"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
