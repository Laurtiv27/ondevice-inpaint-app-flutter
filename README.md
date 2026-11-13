# On-Device Inpaint

[![Flutter](https://img.shields.io/badge/Flutter-3.12%2B-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Android%20%7C%20iOS-lightgrey)](#build)
[![Model](https://img.shields.io/badge/model-LaMa%20ONNX-orange)](#model--attribution)

**Erase watermarks, subtitles, and unwanted objects — entirely on your phone.**

A Flutter app that runs [LaMa](https://github.com/advimman/lama) inpainting locally via ONNX Runtime. Images never leave the device.

---

## Features

- Brush to mark regions, then one-tap inpaint
- On-device inference (ONNX Runtime + LaMa FP32) — no cloud upload
- Adjustable brush size (S / M / L), pinch-zoom canvas
- Pick from gallery and save results to the system album
- Android & iOS; unsigned iOS IPA via GitHub Actions

## Demo

| Select & paint | Inpaint result |
|---------------|----------------|
| _Add screenshots here_ | _Add screenshots here_ |

> Tip: drop PNGs under `docs/` and link them above when ready.

## Requirements

- [Flutter](https://docs.flutter.dev/get-started/install) SDK **3.12+**
- [Git LFS](https://git-lfs.com/) (model is ~208MB and stored via LFS)
- Android device/emulator, or iOS device (see [Build](#build))

## Quick Start

```bash
git lfs install
git clone https://github.com/Laurtiv27/ondevice-inpaint-app-flutter.git
cd ondevice-inpaint-app-flutter
git lfs pull

flutter pub get
flutter run
```

List devices and target one:

```bash
flutter devices
flutter run -d <device_id>
```

## How It Works

```text
Gallery image ──► paint mask ──► LaMa (ONNX, isolate) ──► preview / save
```

1. Pick an image from the gallery
2. Paint over the area to remove
3. The stroke is rasterized into a mask and fed to LaMa with the RGB image
4. Inference runs in a Dart isolate via ONNX Runtime; the result is shown and can be saved

## Project Structure

```text
lib/
  main.dart
  ui/
    editor_page.dart      # pick / paint / run / save
    paint_canvas.dart     # canvas & strokes
  inference/
    inpaint_model.dart    # ONNX load + isolate inference
assets/
  lama_fp32.onnx          # LaMa weights (Git LFS)
  model_version
.github/workflows/
  build-ios-unsigned.yml  # unsigned IPA on macOS runners
```

## Build

### Android

```bash
flutter build apk --release
# or
flutter build appbundle --release
```

### iOS (unsigned IPA, no paid Apple Developer account)

Workflow: **Build iOS IPA (unsigned, free)**

1. Push to `main`, or run the workflow manually in Actions
2. Download the `Runner.ipa` artifact
3. Install with [Sideloadly](https://sideloadly.io/) + a free Apple ID

With a Mac locally:

```bash
flutter build ios --no-codesign
```

## Model & Attribution

| Item | Detail |
|------|--------|
| Architecture | [LaMa](https://github.com/advimman/lama) (Large Mask Inpainting) |
| Runtime | [onnxruntime](https://pub.dev/packages/onnxruntime) |
| Bundle | `assets/lama_fp32.onnx` (~208MB, Git LFS) |

The LaMa model and its original training code are subject to their upstream licenses (see the LaMa repository). This app’s **application source code** is licensed separately under MIT (below).

## Notes

- First clone/install is large because of the model weights
- Latency depends on device and resolution; prefer real devices for timing
- Use only on images you have rights to process; follow local laws

## Contributing

Issues and pull requests are welcome. For larger changes, open an issue first so we can align on scope.

## License

This project’s source code is licensed under the [MIT License](LICENSE).

```text
MIT License
Copyright (c) 2026 Laurtiv27
```

Third-party packages and the LaMa model retain their own licenses.
