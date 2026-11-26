// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Exit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Exit",
            path: "Sources/Exit",
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Security"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
