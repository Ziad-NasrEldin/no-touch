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
        .library(name: "AudioCapture", targets: ["AudioCapture"]),
        .library(name: "WatchCapture", targets: ["WatchCapture"]),
        .library(name: "PhoneAI", targets: ["PhoneAI"]),
        .library(name: "PhoneStorage", targets: ["PhoneStorage"]),
        .library(name: "PhoneIntegration", targets: ["PhoneIntegration"])
    ],
    dependencies: [
        // A1 §4.1 exact registrations — iOS/macOS-only model stacks, bound
        // to the PhoneAI target only (watch targets must never pull these).
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.1"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", .upToNextMinor(from: "2.31.3"))
    ],
    targets: [
        .target(name: "RecorderContracts"),
        .target(name: "AudioCapture", dependencies: ["RecorderContracts"]),
        .target(name: "WatchCapture", dependencies: ["RecorderContracts", "AudioCapture"]),
        .target(
            name: "PhoneAI",
            dependencies: [
                "RecorderContracts",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm")
            ]
        ),
        .target(name: "PhoneStorage", dependencies: ["RecorderContracts"]),
        .target(
            name: "PhoneIntegration",
            dependencies: ["RecorderContracts", "AudioCapture", "PhoneAI", "PhoneStorage"]
        )
    ]
)
