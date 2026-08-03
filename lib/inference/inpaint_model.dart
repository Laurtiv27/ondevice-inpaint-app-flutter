import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

/// 原始分辨率 RGBA8888 位图。等价于原生 `Bitmap` + `int[] px`，
/// 但用连续字节存储，可零成本喂给 `ui.decodeImageFromPixels` 直接上屏。
class RgbaImage {
  final int width;
  final int height;
  final Uint8List pixels; // 长度 = width * height * 4

  const RgbaImage(this.width, this.height, this.pixels);
}

/// 一笔涂抹：点坐标是「原图像素」坐标，[brush] 是笔宽（原图像素直径）。
/// 每笔单独记录笔宽，与原生把笔迹烘焙进 paintBmp 的行为一致
/// （改笔刷大小只影响之后画的笔迹）。
class Stroke {
  final List<Offset> points;
  final double brush;
  const Stroke(this.points, this.brush);
}

/// 全部笔迹的矢量描述。可在任意子区域内光栅化成 0/255 单通道遮罩。
/// 语义对齐原生 `Paint(STROKE, ROUND cap, ROUND join, width=brushSize)`：
/// 即「到线段的距离 <= 半径」的实心圆头粗线。
class MaskStrokes {
  final List<Stroke> strokes;
  const MaskStrokes(this.strokes);

  bool get isEmpty {
    for (final s in strokes) {
      if (s.points.isNotEmpty) return false;
    }
    return true;
  }

  /// 已涂抹区域的包围盒（含笔刷半径），裁剪到图像范围内。
  /// 返回 [minX, minY, maxX, maxY]；没有有效笔迹时返回 null。
  List<int>? boundsInt(int imgW, int imgH) {
    double lo = double.infinity, to = double.infinity;
    double ro = -double.infinity, bo = -double.infinity;
    for (final s in strokes) {
      final r = s.brush / 2.0;
      for (final p in s.points) {
        if (p.dx - r < lo) lo = p.dx - r;
        if (p.dy - r < to) to = p.dy - r;
        if (p.dx + r > ro) ro = p.dx + r;
        if (p.dy + r > bo) bo = p.dy + r;
      }
    }
    if (lo == double.infinity) return null;
    final minX = math.max(0, lo.floor());
    final minY = math.max(0, to.floor());
    final maxX = math.min(imgW - 1, ro.ceil());
    final maxY = math.min(imgH - 1, bo.ceil());
    if (maxX < minX || maxY < minY) return null;
    return [minX, minY, maxX, maxY];
  }

  /// 在以原图坐标 (ox, oy) 为原点、尺寸 w×h 的窗口内光栅化遮罩。
  Uint8List rasterize(int ox, int oy, int w, int h) {
    final m = Uint8List(w * h);
    for (final s in strokes) {
      final pts = s.points;
      if (pts.isEmpty) continue;
      final r = s.brush / 2.0;
      if (pts.length == 1) {
        final p = pts[0];
        _stampSegment(m, w, h, p.dx - ox, p.dy - oy, p.dx - ox, p.dy - oy, r);
        continue;
      }
      for (int i = 1; i < pts.length; i++) {
        final a = pts[i - 1];
        final b = pts[i];
        _stampSegment(m, w, h, a.dx - ox, a.dy - oy, b.dx - ox, b.dy - oy, r);
      }
    }
    return m;
  }
}

/// 把一段「圆头粗线」（capsule）盖到遮罩上。
void _stampSegment(Uint8List m, int w, int h, double x0, double y0, double x1,
    double y1, double r) {
  final r2 = r * r;
  int lo = (math.min(x0, x1) - r).floor();
  int hi = (math.max(x0, x1) + r).ceil();
  int to = (math.min(y0, y1) - r).floor();
  int bo = (math.max(y0, y1) + r).ceil();
  if (lo < 0) lo = 0;
  if (to < 0) to = 0;
  if (hi > w - 1) hi = w - 1;
  if (bo > h - 1) bo = h - 1;
  if (lo > hi || to > bo) return;

  final dx = x1 - x0;
  final dy = y1 - y0;
  final len2 = dx * dx + dy * dy;

  for (int y = to; y <= bo; y++) {
    final py = y + 0.5 - y0;
    final row = y * w;
    for (int x = lo; x <= hi; x++) {
      final px = x + 0.5 - x0;
      double t = 0;
      if (len2 > 0) {
        t = (px * dx + py * dy) / len2;
        if (t < 0) t = 0;
        if (t > 1) t = 1;
      }
      final ex = px - t * dx;
      final ey = py - t * dy;
      if (ex * ex + ey * ey <= r2) m[row + x] = 255;
    }
  }
}

/// 预处理产物（在后台 isolate 中生成）。
class _PreData {
  final Float32List imgF; // [3, S, S]
  final Float32List maskF; // [S, S]
  final Uint8List maskCrop; // cropW * cropH，0/255
  const _PreData(this.imgF, this.maskF, this.maskCrop);
}

/// 端侧 LaMa 去水印。算法与原生 `MainActivity.runRepair()` 逐行等价：
/// 遮罩包围盒 +200px 上下文裁剪 → 双线性缩放到 S×S → ONNX 推理 →
/// 双线性放大 → boxBlur 羽化后 alpha 混合回**原分辨率**原图。
class InpaintModel {
  OrtSession? _session;
  bool get isReady => _session != null;

  static const List<int> inputSizes = [512, 384, 256];
  static const int pad = 200; // 与原生 PAD 一致
  int modelInputSize = 384;

  /// 把 asset 里的模型复制到应用目录（带版本哨兵），再建 ORT 会话。
  Future<void> loadModel() async {
    final dir = await getApplicationDocumentsDirectory();
    final modelFile = File('${dir.path}/lama_fp32.onnx');
    final versionFile = File('${dir.path}/model_version');

    final assetVer =
        (await rootBundle.loadString('assets/model_version')).trim();
    String curVer = '';
    if (await versionFile.exists()) {
      curVer = (await versionFile.readAsString()).trim();
    }

    if (!await modelFile.exists() || curVer != assetVer) {
      final bytes = await rootBundle.load('assets/lama_fp32.onnx');
      await modelFile.writeAsBytes(bytes.buffer.asUint8List());
      await versionFile.writeAsString(assetVer);
    }

    final options = OrtSessionOptions();
    // XNNPACK EP 自带内部线程池；ORT 线程池若 >1 会与其争抢 CPU，
    // 实测反而更慢。与原生 opts.setIntraOpNumThreads(cores)+addXnnpack
    // 等价，但这里按官方推荐把 ORT 线程设为 1，让 XNNPACK 独占调度。
    options.setIntraOpNumThreads(1);
    // 防御：极少数 iOS 构建/环境下 XNNPACK provider 可能不可用，
    // 此时退回到默认 CPU EP 即可——推理数值完全确定、结果不变，
    // 只是可能稍慢。避免因此导致模型加载直接抛异常、整页白屏。
    try {
      options.appendXnnpackProvider();
    } catch (_) {
      // 退回 CPU EP，无需额外处理
    }
    _session = OrtSession.fromFile(modelFile, options);
  }

  /// 384 → 256 → 512 → …（与原生「画质」按钮循环顺序一致：512→384→256）
  int cycleQuality() {
    final idx = inputSizes.indexOf(modelInputSize);
    modelInputSize = inputSizes[(idx + 1) % inputSizes.length];
    return modelInputSize;
  }

  /// 执行修复。返回与输入等分辨率的新图（未涂抹区域逐字节保持原样）。
  Future<RgbaImage> runRepair(RgbaImage base, MaskStrokes mask) async {
    final session = _session;
    if (session == null) throw Exception('模型加载中，稍后再试');

    final S = modelInputSize;
    final W = base.width;
    final H = base.height;

    final bb = mask.boundsInt(W, H);
    if (bb == null) throw Exception('先用手指涂抹要去掉的水印');

    final x1 = math.max(0, bb[0] - pad);
    final y1 = math.max(0, bb[1] - pad);
    final x2 = math.min(W, bb[2] + pad);
    final y2 = math.min(H, bb[3] + pad);
    final cropW = x2 - x1;
    final cropH = y2 - y1;

    // 只搬运裁剪区，逐行 memcpy（相比逐像素 getPixel 快两个数量级）
    final cropRgba = Uint8List(cropW * cropH * 4);
    final rowBytes = cropW * 4;
    for (int y = 0; y < cropH; y++) {
      final src = ((y + y1) * W + x1) * 4;
      cropRgba.setRange(y * rowBytes, (y + 1) * rowBytes, base.pixels, src);
    }

    // ---- 预处理（后台 isolate，避免卡 UI）----
    final pre = await Isolate.run(
        () => _preprocess(cropRgba, cropW, cropH, mask, x1, y1, S));

    // ---- ONNX 推理 ----
    final imgT = OrtValueTensor.createTensorWithDataList(pre.imgF, [1, 3, S, S]);
    final mskT =
        OrtValueTensor.createTensorWithDataList(pre.maskF, [1, 1, S, S]);
    final runOpts = OrtRunOptions();
    Float32List outF;
    List<OrtValue?>? outputs;
    try {
      outputs = await session.runAsync(runOpts, {
        'image': imgT,
        'mask': mskT,
      });
      if (outputs == null || outputs.isEmpty || outputs[0] == null) {
        throw Exception('模型没有返回结果');
      }
      outF = _flattenNchw(outputs[0]!.value, S);
    } finally {
      imgT.release();
      mskT.release();
      runOpts.release();
      if (outputs != null) {
        for (final o in outputs) {
          o?.release();
        }
      }
    }

    // ---- 后处理（后台 isolate）----
    final maskCrop = pre.maskCrop;
    final blend = await Isolate.run(
        () => _postprocess(outF, S, cropRgba, maskCrop, cropW, cropH));

    // ---- 贴回原图（逐行 memcpy）----
    final resultPx = Uint8List.fromList(base.pixels);
    for (int y = 0; y < cropH; y++) {
      final dst = ((y + y1) * W + x1) * 4;
      resultPx.setRange(dst, dst + rowBytes, blend, y * rowBytes);
    }
    return RgbaImage(W, H, resultPx);
  }

  void dispose() {
    _session?.release();
    _session = null;
  }
}

// ---------------------------------------------------------------------------
// 以下为纯计算函数（顶层函数，可在 isolate 中执行）
// ---------------------------------------------------------------------------

_PreData _preprocess(Uint8List cropRgba, int cropW, int cropH, MaskStrokes mask,
    int ox, int oy, int S) {
  final maskCrop = mask.rasterize(ox, oy, cropW, cropH);
  final imgS = _resizeBilinear(cropRgba, cropW, cropH, S, S, 4);
  final mskS = _resizeBilinear(maskCrop, cropW, cropH, S, S, 1);

  final n = S * S;
  final imgF = Float32List(3 * n);
  final maskF = Float32List(n);
  for (int i = 0; i < n; i++) {
    final o = i * 4;
    imgF[i] = imgS[o] / 255.0; // R -> channel 0（与原生 (p>>16)&0xFF 一致）
    imgF[n + i] = imgS[o + 1] / 255.0; // G
    imgF[2 * n + i] = imgS[o + 2] / 255.0; // B
    maskF[i] = mskS[i] > 10 ? 1.0 : 0.0;
  }
  return _PreData(imgF, maskF, maskCrop);
}

Uint8List _postprocess(Float32List outF, int S, Uint8List cropRgba,
    Uint8List maskCrop, int cropW, int cropH) {
  final n = S * S;

  // 模型输出已是 0~255 量纲；原生用 (int) 截断后 clamp，这里保持一致
  final out8 = Uint8List(n * 4);
  for (int i = 0; i < n; i++) {
    final o = i * 4;
    out8[o] = _clamp8(outF[i]);
    out8[o + 1] = _clamp8(outF[n + i]);
    out8[o + 2] = _clamp8(outF[2 * n + i]);
    out8[o + 3] = 255;
  }

  final outFull = _resizeBilinear(out8, S, S, cropW, cropH, 4);
  final smooth = _boxBlur5(maskCrop, cropW, cropH);

  final count = cropW * cropH;
  final blend = Uint8List(count * 4);
  for (int i = 0; i < count; i++) {
    final a = smooth[i];
    final ia = 1.0 - a;
    final o = i * 4;
    blend[o] = _clamp8(outFull[o] * a + cropRgba[o] * ia);
    blend[o + 1] = _clamp8(outFull[o + 1] * a + cropRgba[o + 1] * ia);
    blend[o + 2] = _clamp8(outFull[o + 2] * a + cropRgba[o + 2] * ia);
    blend[o + 3] = 255;
  }
  return blend;
}

int _clamp8(double v) {
  final i = v.toInt(); // 截断，与原生 (int) 强转一致
  if (i < 0) return 0;
  if (i > 255) return 255;
  return i;
}

/// 双线性缩放，等价于 Android `Bitmap.createScaledBitmap(src, dw, dh, true)`。
/// 采样使用像素中心对齐：srcPos = (dst + 0.5) * scale - 0.5。
Uint8List _resizeBilinear(
    Uint8List src, int sw, int sh, int dw, int dh, int ch) {
  if (sw == dw && sh == dh) return Uint8List.fromList(src);
  final dst = Uint8List(dw * dh * ch);
  final sx = sw / dw;
  final sy = sh / dh;

  // 预计算横向采样索引，避免内层重复计算
  final ix0 = Int32List(dw);
  final ix1 = Int32List(dw);
  final fx = Float32List(dw);
  for (int x = 0; x < dw; x++) {
    double p = (x + 0.5) * sx - 0.5;
    if (p < 0) p = 0;
    int a = p.floor();
    if (a > sw - 1) a = sw - 1;
    int b = a + 1;
    if (b > sw - 1) b = sw - 1;
    ix0[x] = a * ch;
    ix1[x] = b * ch;
    fx[x] = p - a;
  }

  final srcRow = sw * ch;
  final dstRow = dw * ch;
  for (int y = 0; y < dh; y++) {
    double p = (y + 0.5) * sy - 0.5;
    if (p < 0) p = 0;
    int a = p.floor();
    if (a > sh - 1) a = sh - 1;
    int b = a + 1;
    if (b > sh - 1) b = sh - 1;
    final wy = p - a;
    final r0 = a * srcRow;
    final r1 = b * srcRow;
    final dr = y * dstRow;
    for (int x = 0; x < dw; x++) {
      final wx = fx[x];
      final o0 = ix0[x];
      final o1 = ix1[x];
      final od = dr + x * ch;
      for (int c = 0; c < ch; c++) {
        final p00 = src[r0 + o0 + c].toDouble();
        final p01 = src[r0 + o1 + c].toDouble();
        final p10 = src[r1 + o0 + c].toDouble();
        final p11 = src[r1 + o1 + c].toDouble();
        final top = p00 + (p01 - p00) * wx;
        final bot = p10 + (p11 - p10) * wx;
        double v = top + (bot - top) * wy;
        if (v < 0) v = 0;
        if (v > 255) v = 255;
        dst[od + c] = v.round();
      }
    }
  }
  return dst;
}

/// 5×5 均值模糊（radius=5 → r=2, area=25），与原生 `boxBlur(px, w, h, 5)` 等价：
/// 越界样本跳过但**除数固定为 25**（边缘自然衰减）。
/// 这里用行/列前缀和做成 O(N)，取代原来的 O(N·25)。
Float32List _boxBlur5(Uint8List mask, int w, int h) {
  const int r = 2;
  const double area = 25.0;

  final rowSum = Int32List(w * h);
  final prefW = Int32List(w + 1);
  for (int y = 0; y < h; y++) {
    final base = y * w;
    int acc = 0;
    for (int x = 0; x < w; x++) {
      acc += mask[base + x];
      prefW[x + 1] = acc;
    }
    for (int x = 0; x < w; x++) {
      int a = x - r;
      if (a < 0) a = 0;
      int b = x + r;
      if (b > w - 1) b = w - 1;
      rowSum[base + x] = prefW[b + 1] - prefW[a];
    }
  }

  final out = Float32List(w * h);
  final prefH = Int32List(h + 1);
  for (int x = 0; x < w; x++) {
    int acc = 0;
    for (int y = 0; y < h; y++) {
      acc += rowSum[y * w + x];
      prefH[y + 1] = acc;
    }
    for (int y = 0; y < h; y++) {
      int a = y - r;
      if (a < 0) a = 0;
      int b = y + r;
      if (b > h - 1) b = h - 1;
      out[y * w + x] = (prefH[b + 1] - prefH[a]) / area / 255.0;
    }
  }
  return out;
}

/// 把 ORT 输出（[1,3,S,S] 嵌套 List 或扁平 buffer）摊平成 Float32List。
Float32List _flattenNchw(dynamic value, int S) {
  final n = S * S;
  final out = Float32List(3 * n);
  if (value is Float32List) {
    out.setRange(0, math.min(out.length, value.length), value);
    return out;
  }
  final batch = (value as List)[0] as List; // [3, S, S]
  for (int c = 0; c < 3; c++) {
    final plane = batch[c] as List;
    final co = c * n;
    for (int y = 0; y < S; y++) {
      final row = plane[y] as List;
      final ro = co + y * S;
      for (int x = 0; x < S; x++) {
        out[ro + x] = (row[x] as num).toDouble();
      }
    }
  }
  return out;
}
