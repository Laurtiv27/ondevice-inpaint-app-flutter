import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';

import '../inference/inpaint_model.dart';
import 'paint_canvas.dart';

/// 配色与原生 res/values/colors.xml 完全一致
const Color _cBg = Color(0xFF0E3B2D); // bg_dark_green
const Color _cCanvas = Color(0xFF08301F); // canvas_bg
const Color _cAccentDark = Color(0xFF2E7D55); // accent_dark
const Color _cStatus = Color(0xFFA8D5BA); // text_status / text_stat
const Color _cHint = Color(0xFF6FAF8F); // text_hint
const Color _cDivider = Color(0xFF3E6E55); // hint_divider

/// 主界面：1:1 复刻原生 activity_main.xml 的结构与配色。
class EditorPage extends StatefulWidget {
  const EditorPage({super.key});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  final InpaintModel _model = InpaintModel();
  final ImagePicker _picker = ImagePicker();
  final GlobalKey<PaintCanvasState> _canvasKey = GlobalKey<PaintCanvasState>();

  RgbaImage? _base;
  RgbaImage? _result;

  static const List<double> _brushSizes = [64, 100, 150];
  double _brushSize = 64; // 与原生初始值一致

  bool _busy = false;
  bool _modelReady = false;

  String _statRes = '—';
  String _statTime = '—';

  @override
  void initState() {
    super.initState();
    _initModel();
  }

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 模型
  Future<void> _initModel() async {
    try {
      await Gal.requestAccess();
    } catch (_) {/* 忽略，保存时会再要一次 */}
    try {
      await _model.loadModel();
      if (!mounted) return;
      setState(() => _modelReady = true);
      _toast('模型已就绪');
    } catch (e) {
      if (!mounted) return;
      _toast('模型加载失败: $e');
    }
  }

  // ------------------------------------------------------------------ 图像 IO
  /// 用平台原生解码器解码（比纯 Dart 快一个数量级），直接拿到 RGBA 字节。
  Future<RgbaImage> _decodeToRgba(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data =
        await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    final w = image.width;
    final h = image.height;
    image.dispose();
    codec.dispose();
    if (data == null) throw Exception('无法读取像素');
    final px = Uint8List.fromList(data.buffer.asUint8List());
    for (int i = 3; i < px.length; i += 4) {
      px[i] = 255; // 统一为不透明，与原生 ARGB_8888 照片一致
    }
    return RgbaImage(w, h, px);
  }

  Future<Uint8List> _encodePng(RgbaImage src) async {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      src.pixels,
      src.width,
      src.height,
      ui.PixelFormat.rgba8888,
      c.complete,
    );
    final img = await c.future;
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    if (data == null) throw Exception('PNG 编码失败');
    return data.buffer.asUint8List();
  }

  // ------------------------------------------------------------------ 动作
  Future<void> _pick() async {
    try {
      final x = await _picker.pickImage(source: ImageSource.gallery);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      final decoded = await _decodeToRgba(bytes);
      if (!mounted) return;
      setState(() {
        _base = decoded;
        _result = null;
        _statRes = '${decoded.width}×${decoded.height}';
        _statTime = '—';
      });
    } catch (e) {
      _toast('读图失败: $e');
    }
  }

  Future<void> _repair() async {
    final base = _base;
    if (base == null) {
      _toast('先选一张图');
      return;
    }
    if (!_modelReady) {
      _toast('模型加载中，稍后再试');
      return;
    }
    final mask = _canvasKey.currentState?.currentMask();
    if (mask == null || mask.isEmpty) {
      _toast('先用手指涂抹要去掉的水印');
      return;
    }

    setState(() => _busy = true);
    final sw = Stopwatch()..start();
    try {
      final out = await _model.runRepair(base, mask);
      sw.stop();
      if (!mounted) return;
      setState(() {
        _result = out;
        _busy = false;
        _statRes = '${out.width}×${out.height}';
        _statTime = '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s';
      });
      _toast('修复完成 ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s');
    } catch (e) {
      sw.stop();
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('失败: $e');
    }
  }

  Future<void> _save() async {
    final toSave = _result ?? _base;
    if (toSave == null) {
      _toast('先选一张图');
      return;
    }
    try {
      final png = await _encodePng(toSave);
      await Gal.putImageBytes(png,
          name: 'inpaint_${DateTime.now().millisecondsSinceEpoch}');
      _toast('已保存到相册');
    } catch (e) {
      final granted = await Gal.requestAccess();
      if (granted) {
        try {
          final png = await _encodePng(toSave);
          await Gal.putImageBytes(png,
              name: 'inpaint_${DateTime.now().millisecondsSinceEpoch}');
          _toast('已保存到相册');
          return;
        } catch (e2) {
          _toast('保存失败: $e2');
          return;
        }
      }
      _toast('保存失败（无相册权限）');
    }
  }

  void _cycleBrush() {
    final i = _brushSizes.indexOf(_brushSize);
    setState(() => _brushSize = _brushSizes[(i + 1) % _brushSizes.length]);
  }

  void _cycleQuality() {
    final s = _model.cycleQuality();
    setState(() {});
    final tip = s == 512 ? '最清晰' : (s == 384 ? '均衡' : '更快，质量略降');
    _toast('画质 $s · $tip');
  }

  void _toast(String msg) {
    if (!mounted) return;
    final m = ScaffoldMessenger.maybeOf(context);
    if (m == null) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 14)),
      backgroundColor: const Color(0xE6062419),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(milliseconds: 1800),
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 24),
    ));
  }

  // ------------------------------------------------------------------ build
  @override
  Widget build(BuildContext context) {
    final canUndo = _canvasKey.currentState?.canUndo ?? false;
    final canRedo = _canvasKey.currentState?.canRedo ?? false;

    return Scaffold(
      backgroundColor: _cBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Inpaint Pro',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 14),

              // 画布
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: _cCanvas,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _base == null
                      ? const Center(
                          child: Text('点「选图」选择一张照片',
                              style:
                                  TextStyle(color: _cHint, fontSize: 14)),
                        )
                      : PaintCanvas(
                          key: _canvasKey,
                          base: _base!,
                          result: _result,
                          brushSize: _brushSize,
                          onChanged: () => setState(() {}),
                        ),
                ),
              ),

              // 统计行
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(_statRes,
                        style:
                            const TextStyle(color: _cStatus, fontSize: 13)),
                  ),
                  Expanded(
                    child: Text(_statTime,
                        textAlign: TextAlign.end,
                        style:
                            const TextStyle(color: _cStatus, fontSize: 13)),
                  ),
                ],
              ),

              // 进度条
              const SizedBox(height: 10),
              SizedBox(
                height: 6,
                child: _busy
                    ? const LinearProgressIndicator(
                        minHeight: 6,
                        backgroundColor: Color(0xFF14523C),
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Color(0xFF3DAE7A)),
                      )
                    : const SizedBox.shrink(),
              ),

              // 主按钮
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(child: _mainBtn('选图', _pick)),
                  const SizedBox(width: 8),
                  Expanded(
                      child: _mainBtn('修复', _repair, enabled: !_busy)),
                  const SizedBox(width: 8),
                  Expanded(child: _mainBtn('保存', _save)),
                ],
              ),

              // 提示
              const SizedBox(height: 18),
              const Text('涂抹后点修复 · 拖动中线对比 · 回退/向前调整涂抹',
                  style: TextStyle(color: _cHint, fontSize: 13)),

              // 底部工具
              const SizedBox(height: 32),
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _textTool('笔刷 ${_brushSize.round()}', _cycleBrush),
                    _dot(),
                    _iconTool(Icons.undo, canUndo,
                        () => _canvasKey.currentState?.undo()),
                    _dot(),
                    _iconTool(Icons.redo, canRedo,
                        () => _canvasKey.currentState?.redo()),
                    _dot(),
                    _textTool('清空', () {
                      _canvasKey.currentState?.clearAll();
                      setState(() => _result = null);
                    }),
                    _dot(),
                    _textTool('画质 ${_model.modelInputSize}', _cycleQuality),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mainBtn(String label, VoidCallback onTap, {bool enabled = true}) {
    return SizedBox(
      height: 48,
      child: Material(
        color: enabled ? _cAccentDark : const Color(0xFF23604A),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: enabled ? onTap : null,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: enabled ? Colors.white : Colors.white38,
                fontSize: 15,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _dot() => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 2),
        child: Text(' · ', style: TextStyle(color: _cDivider, fontSize: 13)),
      );

  Widget _textTool(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Text(label,
            style: const TextStyle(color: _cHint, fontSize: 13)),
      ),
    );
  }

  Widget _iconTool(IconData icon, bool enabled, VoidCallback onTap) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
        child: Opacity(
          opacity: enabled ? 1.0 : 0.35,
          child: Icon(icon, size: 22, color: Colors.white),
        ),
      ),
    );
  }
}
