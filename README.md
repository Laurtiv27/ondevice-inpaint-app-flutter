# On-Device Inpaint App

端侧 AI 去水印 / 物体擦除 Flutter 应用。基于 **LaMa** ONNX 模型，在手机本地完成涂抹修复，无需上传图片到云端。

## Features

- 涂抹选区后一键 inpaint，擦除水印、字幕、路人等区域
- 端侧推理：ONNX Runtime + LaMa FP32，数据不出设备
- 可调笔刷（小 / 中 / 大），画布缩放平移
- 相册选图、结果保存到系统相册
- Android / iOS 均可运行；提供 GitHub Actions 未签名 IPA 构建流程

## Tech Stack

| 层 | 技术 |
|----|------|
| UI | Flutter (Material 3) |
| 推理 | [onnxruntime](https://pub.dev/packages/onnxruntime) |
| 模型 | LaMa (`assets/lama_fp32.onnx`, ~208MB, Git LFS) |
| 图像 | `image_picker` / `gal` / 平台原生解码 |

## Requirements

- Flutter SDK **3.12+**（见 `pubspec.yaml`）
- Android：真机或模拟器；首次加载模型需足够存储与内存
- iOS：真机侧载可用 GitHub Actions 产物 + Sideloadly（见下方）
- 克隆时启用 Git LFS（模型文件不在普通 git blob 中）

```bash
git lfs install
git clone https://github.com/Laurtiv27/ondevice-inpaint-app-flutter.git
cd ondevice-inpaint-app-flutter
git lfs pull
```

## Getting Started

```bash
flutter pub get
flutter run
```

指定设备：

```bash
flutter devices
flutter run -d <device_id>
```

## Project Structure

```text
lib/
  main.dart                 # 入口
  ui/
    editor_page.dart        # 主编辑页（选图 / 涂抹 / 推理 / 保存）
    paint_canvas.dart       # 画布与笔迹
  inference/
    inpaint_model.dart      # ONNX 加载与 isolate 推理
assets/
  lama_fp32.onnx            # LaMa 模型（LFS）
  model_version             # 模型版本标记
.github/workflows/
  build-ios-unsigned.yml    # macOS 云端打未签名 IPA
```

## How It Works

1. 用户从相册选图，在画布上涂抹要去除的区域  
2. 笔迹光栅化为 mask，与原图一并送入 LaMa  
3. ONNX Runtime 在本地 isolate 中推理，结果写回画布并可保存  

## Build

### Android

```bash
flutter build apk --release
# 或
flutter build appbundle --release
```

### iOS（未签名 IPA，无需本机 Mac / 付费开发者账号）

仓库已配置 Actions：`Build iOS IPA (unsigned, free)`。

1. Push 到 `main`，或在 Actions 页手动 **Run workflow**
2. 下载 Artifact 中的 `Runner.ipa`
3. 用 [Sideloadly](https://sideloadly.io/) + 免费 Apple ID 安装到 iPhone

本地有 Mac 时也可：

```bash
flutter build ios --no-codesign
```

## Notes

- 模型体积较大，首次克隆与安装包体积会明显高于普通 Flutter 应用
- 推理耗时与机型、分辨率相关；大图建议在真机上评估
- 本仓库为个人/演示用途，使用时请遵守当地法律法规与图片版权要求

## License

未单独声明许可时，以仓库所有者约定为准。欢迎 Issue / PR。
