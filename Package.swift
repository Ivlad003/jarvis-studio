// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "KosmoNotesCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AudioDSP", targets: ["AudioDSP"]),
        .library(name: "CaptureKit", targets: ["CaptureKit"]),
        .library(name: "TranscriptionKit", targets: ["TranscriptionKit"]),
        .library(name: "AIKit", targets: ["AIKit"]),
        .library(name: "StorageKit", targets: ["StorageKit"]),
        .library(name: "DependencyLifecycle", targets: ["DependencyLifecycle"]),
        .library(name: "DictationKit", targets: ["DictationKit"]),
        .library(name: "SharingKit", targets: ["SharingKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "2.2.0"),
        // WhisperKit — Argmax's CoreML port of OpenAI Whisper. Used by the
        // optional on-device transcription path. Models are downloaded at
        // runtime from HuggingFace into Application Support, NOT bundled —
        // keeps the .app under the 15 MB target.
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
    ],
    targets: [
        // MARK: - Library targets

        .target(
            name: "AudioDSP",
            path: "Sources/AudioDSP"
        ),
        .target(
            name: "CaptureKit",
            dependencies: [
                "AudioDSP",
                "StorageKit",
            ],
            path: "Sources/CaptureKit"
        ),
        .target(
            name: "TranscriptionKit",
            dependencies: [
                "StorageKit",
                "AIKit",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/TranscriptionKit"
        ),
        .target(
            name: "AIKit",
            dependencies: [
                "StorageKit",
            ],
            path: "Sources/AIKit"
        ),
        .target(
            name: "StorageKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "KeychainAccess", package: "KeychainAccess"),
            ],
            path: "Sources/StorageKit"
        ),
        .target(
            name: "DependencyLifecycle",
            dependencies: [
                "StorageKit",
            ],
            path: "Sources/DependencyLifecycle"
        ),
        .target(
            name: "DictationKit",
            dependencies: [
                "TranscriptionKit",
                "AIKit",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/DictationKit"
        ),
        .target(
            name: "SharingKit",
            dependencies: [
                "StorageKit",
            ],
            path: "Sources/SharingKit"
        ),

        // MARK: - Test targets

        .testTarget(
            name: "AudioDSPTests",
            dependencies: ["AudioDSP"],
            path: "Tests/AudioDSPTests"
        ),
        .testTarget(
            name: "CaptureKitTests",
            dependencies: ["CaptureKit"],
            path: "Tests/CaptureKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "TranscriptionKitTests",
            dependencies: ["TranscriptionKit"],
            path: "Tests/TranscriptionKitTests"
        ),
        .testTarget(
            name: "AIKitTests",
            dependencies: ["AIKit"],
            path: "Tests/AIKitTests"
        ),
        .testTarget(
            name: "StorageKitTests",
            dependencies: ["StorageKit"],
            path: "Tests/StorageKitTests"
        ),
        .testTarget(
            name: "DependencyLifecycleTests",
            dependencies: ["DependencyLifecycle"],
            path: "Tests/DependencyLifecycleTests"
        ),
        .testTarget(
            name: "DictationKitTests",
            dependencies: ["DictationKit"],
            path: "Tests/DictationKitTests"
        ),
        .testTarget(
            name: "SharingKitTests",
            dependencies: [
                "SharingKit",
                "StorageKit",
            ],
            path: "Tests/SharingKitTests"
        ),
    ]
)
