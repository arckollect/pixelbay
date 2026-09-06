# Pixelbay

A native macOS screen recorder and video editor, built with Swift, SwiftUI, and Metal.

Record your display, a window, or a region — with webcam, microphone, and system audio — then polish the result in a built-in editor with automatic zooms, a cursor-following camera, and styled backgrounds. Export to H.264 MP4.

> **Status:** early and under active development. Expect rough edges and breaking changes to the project format.

## Features

- **Capture** — display, window, or area, driven by ScreenCaptureKit. Webcam, mic, and system audio recorded as separate tracks so they stay editable.
- **Scenes** — record multiple takes into one project and compose them on the timeline.
- **Auto-zoom** — zoom keyframes generated from clicks and cursor gestures, with a smoothed cursor-following camera and real temporal motion blur.
- **Layouts & backgrounds** — picture-in-picture and split layouts, rounded corners and padding, mesh-gradient and image wallpapers, or a sample of your own desktop.
- **Timeline editor** — trim, split, mute, and arrange video, audio, and effect rows; live preview rendered by the same Metal pipeline used for export.
- **Export** — H.264 MP4 rendered through a single shared compositor, so what you preview is what you get.

## Requirements

- macOS 14.6 or later
- Xcode 26 (the `Makefile` uses whatever `xcode-select -p` points at; override with `DEVELOPER_DIR=…`)
- Apple Silicon recommended for compositor performance

## Building

```bash
git clone https://github.com/arckollect/pixelbay.git
cd pixelbay
cp Local.xcconfig.template Local.xcconfig   # then set DEVELOPMENT_TEAM to your Apple Team ID
open Pixelbay.xcworkspace                    # select the PixelbayApp scheme and run
```

Signing config lives in `Local.xcconfig` (gitignored) so no Team ID is ever committed. See the template's comments if you want to build with a self-signed certificate instead.

From the command line:

```bash
make build          # build the app via the workspace
make test           # run every package's test suite
make test-PixelbayCore
```

On first launch macOS will ask for **Screen Recording**, **Camera**, **Microphone**, and **Accessibility** (used for cursor tracking that powers auto-zoom). The app is not sandboxed — it ships as a notarized direct download, not through the Mac App Store.

## Architecture

The app target is thin; almost everything lives in local Swift packages under `Packages/`, each independently testable with `swift test`.

```
Packages/
├── PixelbayCore/            Project model, schema + migrations, bundle I/O
├── PixelbayCapture/         ScreenCaptureKit + AVCaptureSession orchestration
├── PixelbayRecording/       AVAssetWriter pipeline
├── PixelbayCompositor/      Metal render graph — preview and export share it
├── PixelbayPlayback/        AVPlayer + AVMutableComposition glue
├── PixelbayEditor/          Timeline operations, auto-zoom generation, undo
├── PixelbayTimelineUI/      Timeline view (SwiftUI + AppKit)
├── PixelbayInputCapture/    CGEventTap wrappers for cursor and click logging
├── PixelbayPermissions/     Permission state machine + onboarding
└── PixelbayDesignSystem/    Theme tokens, components, bundled wallpapers
PixelbayApp/                 Xcode app target
```

Projects are saved as `.pixelbay` bundles: a `project.json` document plus the raw recorded media, so edits are non-destructive and the originals are never touched.

## Contributing

Issues and pull requests are welcome. Please run `make test` before opening a PR.

## Acknowledgements

The zoom-motion constants and auto-zoom heuristics are ported from [OpenScreen](https://github.com/siddharthvaddem/openscreen) (MIT). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for details and dependency licenses.

## License

[MIT](LICENSE)
