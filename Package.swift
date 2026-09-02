// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "otp-bar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "otp-bar",
            path: "Sources/otp-bar"
        ),
        .testTarget(
            name: "otp-barTests",
            dependencies: ["otp-bar"],
            path: "Tests/otp-barTests"
        )
    ]
)
