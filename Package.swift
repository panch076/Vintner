// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Vintner",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "Vintner",
            path: "Sources/Vintner",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("AppKit"),
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
