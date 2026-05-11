// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "YouSage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "YouSage",
            path: "Sources/YouSage"
        )
    ],
    swiftLanguageModes: [.v5]
)
