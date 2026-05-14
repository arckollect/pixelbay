# Pixelbay

A native macOS screen recorder and non-linear video editor.

Status: **Phase 1 (MVP) — scaffolding.** See the roadmap for the full roadmap.

## Requirements

- macOS 14 Sonoma or later (target)
- Xcode 15.4+ / Swift 6
- Apple Silicon recommended (compositor performance)

## Layout

```
pixelbay/
├── PixelbayApp/                 # Xcode app target (created in Xcode — see "Wiring Up the Workspace")
│   └── PixelbayApp/
│       ├── Info.plist           # Usage strings (NSCameraUsageDescription, etc.)
│       └── Pixelbay.entitlements
└── Packages/                    # Local SwiftPM library packages
    ├── PixelbayCore/            # ProjectModel, schema, migrators, bundle I/O
    ├── PixelbayCapture/         # SCStream + AVCaptureSession orchestration
    ├── PixelbayRecording/       # AVAssetWriter pipeline
    ├── PixelbayCompositor/      # Metal render graph (preview + export share this)
    ├── PixelbayEditor/          # Pure model: timeline ops, non-destructive edits
    ├── PixelbayPlayback/        # AVPlayer + AVMutableComposition glue
    ├── PixelbayTimelineUI/      # SwiftUI chrome + AppKit-hosted timeline view
    ├── PixelbayInputCapture/    # CGEventTap wrappers (clicks, keystrokes)
    └── PixelbayPermissions/     # Permission state machine + onboarding
```

## Wiring Up the Workspace

Pixelbay is structured as a set of local SwiftPM packages that an Xcode app target consumes. The `PixelbayApp.xcodeproj` is **not** committed yet — you create it on first checkout:

1. Open Xcode → File → New → Project → macOS → App.
2. Product Name: `PixelbayApp`. Interface: SwiftUI. Language: Swift. Save into `PixelbayApp/`.
3. Replace the generated `Info.plist` and entitlements file with the ones already in `PixelbayApp/PixelbayApp/`.
4. Set the deployment target to macOS 14.0.
5. Disable "App Sandbox" capability (we ship direct-download, not Mac App Store).
6. Enable the "Hardened Runtime" capability with `Camera` and `Audio Input` checked.
7. File → Add Package Dependencies → Add Local → select each `Packages/<Name>` directory and add the corresponding library product to the app target.
8. (Optional) File → New → Workspace, save as `Pixelbay.xcworkspace` at the repo root, drag in `PixelbayApp.xcodeproj` and the `Packages` folder.

## Building and Testing the Core Module

The core schema can be built and tested without Xcode:

```bash
cd Packages/PixelbayCore
swift build
swift test
```

## Phase 1 Scope

See the roadmap. v0.1 records (display **or** window) + webcam + mic + system audio, plays back with a fixed default layout (cam bottom-right), and exports H.264 MP4 at one preset. No timeline editing yet.
