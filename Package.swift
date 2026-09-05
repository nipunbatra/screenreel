// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Aks",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "aks", targets: ["AksCLI"]),
        .executable(name: "AksApp", targets: ["AksApp"]),
        .library(name: "ProjectModel", targets: ["ProjectModel"]),
        .library(name: "CaptureCore", targets: ["CaptureCore"]),
        .library(name: "EventCapture", targets: ["EventCapture"]),
        .library(name: "Diagnostics", targets: ["Diagnostics"]),
        .library(name: "Licensing", targets: ["Licensing"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // MARK: Core (Milestone 0)
        .target(name: "ProjectModel"),
        .target(name: "Diagnostics", dependencies: ["ProjectModel"]),
        .target(name: "EventCapture", dependencies: ["ProjectModel", "Diagnostics"]),
        .target(name: "CaptureCore", dependencies: ["ProjectModel", "Diagnostics", "EventCapture"]),
        // App-side pure logic (preferences, hotkey presets, area-picker
        // geometry): a library so it is unit-testable — the AksApp
        // executable target cannot be imported by tests.
        .target(name: "AppSupport"),
        .executableTarget(
            name: "AksApp",
            dependencies: [
                "ProjectModel", "CaptureCore", "EventCapture", "Diagnostics",
                "PreviewEngine", "ExportEngine", "MotionEngine", "TimelineCore",
                "RenderGraph", "Captions", "Licensing", "AppSupport",
            ]
        ),
        .executableTarget(
            name: "AksCLI",
            dependencies: [
                "ProjectModel", "CaptureCore", "EventCapture", "Diagnostics",
                "ExportEngine", "Captions", "TimelineCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // MARK: Distribution (offline license keys, update-check policy)
        // Foundation + CryptoKit only; no other package dependencies.
        .target(name: "Licensing"),

        // MARK: Interfaces/stubs (implemented in later milestones)
        .target(name: "TimelineCore", dependencies: ["ProjectModel"]),
        .target(name: "MotionEngine", dependencies: ["ProjectModel", "TimelineCore"]),
        .target(name: "AudioPipeline", dependencies: ["ProjectModel"]),
        .target(name: "Captions", dependencies: ["ProjectModel", "TimelineCore"]),
        .target(name: "RenderGraph", dependencies: ["ProjectModel", "TimelineCore", "MotionEngine"]),
        .target(
            name: "PreviewEngine",
            dependencies: ["RenderGraph", "ProjectModel", "MotionEngine", "TimelineCore"]),
        .target(
            name: "ExportEngine",
            dependencies: [
                "ProjectModel", "RenderGraph", "CaptureCore",
                "PreviewEngine", "MotionEngine", "TimelineCore", "AudioPipeline",
            ]),

        // MARK: Tests
        .testTarget(
            name: "AudioPipelineTests",
            dependencies: ["AudioPipeline"]),
        .testTarget(
            name: "CaptionsTests",
            dependencies: ["Captions", "TimelineCore", "ProjectModel"]),
        .testTarget(
            name: "ProjectModelTests",
            dependencies: ["ProjectModel"],
            exclude: ["Fixtures"]  // accessed via #filePath, not bundle resources
        ),
        .testTarget(name: "CaptureCoreTests", dependencies: ["CaptureCore"]),
        .testTarget(name: "DiagnosticsTests", dependencies: ["Diagnostics", "ProjectModel"]),
        .testTarget(name: "MotionEngineTests", dependencies: ["MotionEngine", "TimelineCore"]),
        .testTarget(name: "TimelineCoreTests", dependencies: ["TimelineCore", "ProjectModel"]),
        .testTarget(
            name: "PreviewEngineTests",
            dependencies: ["PreviewEngine", "CaptureCore", "ProjectModel"]),
        .testTarget(
            name: "RenderGraphTests",
            dependencies: ["RenderGraph", "MotionEngine", "TimelineCore"]
        ),
        .testTarget(name: "EventCaptureTests", dependencies: ["EventCapture"]),
        .testTarget(name: "LicensingTests", dependencies: ["Licensing"]),
        .testTarget(name: "AksAppLogicTests", dependencies: ["AppSupport"]),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "ProjectModel", "CaptureCore", "EventCapture", "ExportEngine",
                "PreviewEngine", "AksCLI",
            ]
        ),
    ]
)
