# ADR 0001 — Platform and package baseline for Milestone 0

- Status: accepted
- Date: 2026-08-24

## Context

Milestone 0 requires a Swift package/module skeleton, versioned schemas, durable
capture, and a validator/recovery CLI. The specification recommends SwiftUI/AppKit,
ScreenCaptureKit, AVFoundation, and small packages with protocol boundaries, but
leaves the minimum macOS version and the package topology open. The project owner
confirmed on 2026-08-24 that the development machine (Apple M2 Max, macOS 15.7,
Xcode 26.3, Swift 6.2) is the baseline and chose a macOS 15 minimum.

## Decision

1. **Minimum platform: macOS 15.** This allows `SCStream` to capture the
   microphone inside the same ScreenCaptureKit session as screen and system
   audio, so all capture timestamps originate from one capture stack. The
   floor is revisited before any public release (ROADMAP "Decisions required
   before public release").
2. **One SwiftPM package at the repository root with many small targets**, not
   separate repositories or a monolithic app target. Targets follow the module
   map in `CLAUDE.md` (`ProjectModel`, `CaptureCore`, `EventCapture`,
   `Diagnostics`, `AksCLI`, plus stub targets for `TimelineCore`,
   `MotionEngine`, `AudioPipeline`, `RenderGraph`, `PreviewEngine`,
   `ExportEngine`). Only app/preview targets may import SwiftUI.
3. **Swift 6 language mode** with strict concurrency. Long-lived media state is
   owned by actors; sample-buffer paths never hop through `@MainActor`.
4. **External dependencies are limited to `apple/swift-argument-parser`** (CLI
   only) in Milestone 0. Hashing uses CryptoKit; no third-party crypto.
5. **`aks` (the CLI) is the first executable product.** The SwiftUI shell comes
   after the durable recorder passes its gates, per the roadmap. During
   development the CLI records real sessions using the Screen Recording
   permission of the invoking terminal.

## Consequences

- No fallback microphone path (AVCaptureSession/AVAudioEngine) is required in
  Milestone 0; a pre-15 floor would reintroduce it behind the same
  `AudioSource` protocol.
- CI/tests must run on macOS 15+.
- Schema validation is enforced by strict `Codable` decoding plus the
  `ProjectModel` validator. The JSON Schema documents in `Schemas/` are the
  normative cross-tool contract and are covered by fixture tests.
