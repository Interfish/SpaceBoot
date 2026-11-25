// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpaceBoot",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SpaceBoot", targets: ["SpaceBoot"])
    ],
    targets: [
        .executableTarget(
            name: "SpaceBoot",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("UserNotifications")
            ]
        )
    ]
)
