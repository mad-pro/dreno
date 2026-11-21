// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Dreno",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Dreno",
            path: "Sources/Dreno",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
