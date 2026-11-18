// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WatchRecorder",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14)
    ],
    products: [
        .library(name: "RecorderContracts", targets: ["RecorderContracts"]),
        .library(name: "WatchCapture", targets: ["WatchCapture"]),
        .library(name: "PhoneAI", targets: ["PhoneAI"]),
        .library(name: "PhoneStorage", targets: ["PhoneStorage"]),
        .library(name: "PhoneIntegration", targets: ["PhoneIntegration"])
    ],
    targets: [
        .target(name: "RecorderContracts"),
        .target(name: "WatchCapture", dependencies: ["RecorderContracts"]),
        .target(name: "PhoneAI", dependencies: ["RecorderContracts"]),
        .target(name: "PhoneStorage", dependencies: ["RecorderContracts"]),
        .target(
            name: "PhoneIntegration",
            dependencies: ["RecorderContracts", "PhoneAI", "PhoneStorage"]
        )
    ]
)
