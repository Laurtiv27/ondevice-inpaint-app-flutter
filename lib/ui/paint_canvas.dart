import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../inference/inpaint_model.dart';

/// 双模画布，与原生 `CompareView` 行为一一对应：
///  - EDIT   ：原图 + 半透明白色涂抹遮罩，手指按下即开始涂
///  - COMPARE：左右分屏（左原图+遮罩 / 右修复结果），中间圆形手柄可拖动分割线；
///             点手柄以外任意位置立即回到 EDIT 继续涂抹
///
/// 图像用 contain 方式居中缩放（scale = min(vw/w, vh/h)），
/// 与原生 `computeTransform()` 完全一致 —— 这是触摸坐标能对准像素的前提。
class PaintCanvas extends StatefulWidget {
  final RgbaImage base;
  final RgbaImage? result;
  final double brushSize;
  final VoidCallback? onChanged;

  const PaintCanvas({
    super.key,
    required this.base,
    required this.brushSize,
    this.result,
    this.onChanged,
  });

  @override
  State<PaintCanvas> createState() => PaintCanvasState();
}

class PaintCanvasState extends State<PaintCanvas> {
  static const int _modeEdit = 0;
  static const int _modeCompare = 1;
  static const double _handleR = 22;

  ui.Image? _baseUi;
  ui.Image? _resultUi;

  final List<Stroke> _strokes = [];
  final List<Stroke> _redoStack = [];
  List<Offset>? _current;

  int _mode = _modeEdit;
  double _splitX = 0.5;
  bool _draggingSplit = false;

  double _scale = 1, _offX = 0, _offY = 0;

  @override
  void initState() {
    super.initState();
    _loadBase();
  }

  @override
  void didUpdateWidget(covariant PaintCanvas oldWidget) {
    final old = oldWidget;
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.base, old.base)) {
      _strokes.clear();
      _redoStack.clear();
      _current = null;
      _splitX = 0.5;
      _mode = _modeEdit;
      _resultUi?.dispose();
      _resultUi = null;
      _loadBase();
    }
    if (!identical(widget.result, old.result)) {
      _resultUi?.dispose();
      _resultUi = null;
      if (widget.result != null) {
        _loadResult(widget.result!);
      } else {
        _mode = _modeEdit;
      }
    }
  }

  Future<ui.Image> _decode(RgbaImage src) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      src.pixels,
      src.width,
      src.height,
      ui.PixelFormat.rgba8888,
      c.complete,
    );
    return c.future;
  }

  Future<void> _loadBase() async {
    final img = await _decode(widget.base);
    if (!mounted) {
      img.dispose();
      return;
    }
    setState(() {
      _baseUi?.dispose();
      _baseUi = img;
    });
  }

  Future<void> _loadResult(RgbaImage src) async {
    final img = await _decode(src);
    if (!mounted || !identical(widget.result, src)) {
      img.dispose();
      return;
    }
    setState(() {
      _resultUi = img;
      _mode = _modeCompare;
      _splitX = 0.5;
    });
  }

  @override
  void dispose() {
    _baseUi?.dispose();
    _resultUi?.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 对外 API
  bool get canUndo => _strokes.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;
  bool get inCompare => _mode == _modeCompare && _resultUi != null;

  /// 当前全部笔迹的矢量描述，交给推理管线在裁剪区内光栅化。
  MaskStrokes currentMask() => MaskStrokes(List<Stroke>.unmodifiable(_strokes));

  void undo() {
    if (_strokes.isEmpty) return;
    _redoStack.add(_strokes.removeLast());
    _leaveCompare();
    _notify();
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    _strokes.add(_redoStack.removeLast());
    _leaveCompare();
    _notify();
  }

  /// 清空：丢弃全部涂抹与修复预览，回到原图。
  void clearAll() {
    _strokes.clear();
    _redoStack.clear();
    _current = null;
    _leaveCompare();
    _notify();
  }

  void _leaveCompare() {
    _resultUi?.dispose();
    _resultUi = null;
    _mode = _modeEdit;
    _splitX = 0.5;
  }

  void _notify() {
    if (mounted) setState(() {});
    widget.onChanged?.call();
  }

  // ------------------------------------------------------------------ 手势
  Offset? _toImage(Offset local) {
    final b = _baseUi;
    if (b == null) return null;
    final bx = (local.dx - _offX) / _scale;
    final by = (local.dy - _offY) / _scale;
    if (bx < 0 || by < 0 || bx >= b.width || by >= b.height) return null;
    return Offset(bx, by);
  }

  Offset _handleCenter() {
    final b = _baseUi!;
    return Offset(
      _offX + _splitX * b.width * _scale,
      _offY + (b.height * _scale) / 2,
    );
  }

  void _onDown(PointerDownEvent e) {
    if (_baseUi == null) return;
    if (inCompare) {
      final h = _handleCenter();
      final dx = e.localPosition.dx - h.dx;
      final dy = e.localPosition.dy - h.dy;
      if (dx.abs() <= _handleR + 16 && dy.abs() <= _handleR + 32) {
        _draggingSplit = true;
        return;
      }
      // 点手柄以外 -> 立刻回到编辑模式，并接着这一笔继续涂抹
      _leaveCompare();
      widget.onChanged?.call();
    }
    final p = _toImage(e.localPosition);
    if (p == null) {
      setState(() {});
      return;
    }
    _current = [p];
    setState(() {});
  }

  void _onMove(PointerMoveEvent e) {
    if (_baseUi == null) return;
    if (_draggingSplit) {
      final b = _baseUi!;
      final vx = (e.localPosition.dx - _offX) / _scale;
      setState(() => _splitX = (vx / b.width).clamp(0.0, 1.0));
      return;
    }
    if (_current == null) return;
    final p = _toImage(e.localPosition);
    if (p == null) return;
    _current!.add(p);
    setState(() {});
  }

  void _onUp() {
    if (_draggingSplit) {
      _draggingSplit = false;
      return;
    }
    final cur = _current;
    _current = null;
    if (cur != null && cur.isNotEmpty) {
      _strokes.add(Stroke(cur, widget.brushSize));
      _redoStack.clear();
      _notify();
    } else {
      setState(() {});
    }
  }

  // ------------------------------------------------------------------ build
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, cons) {
        final vw = math.max(cons.maxWidth, 1.0);
        final vh = math.max(cons.maxHeight, 1.0);
        final b = _baseUi;
        if (b != null) {
          _scale = math.min(vw / b.width, vh / b.height);
          _offX = (vw - b.width * _scale) / 2;
          _offY = (vh - b.height * _scale) / 2;
        }
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onDown,
          onPointerMove: _onMove,
          onPointerUp: (_) => _onUp(),
          onPointerCancel: (_) => _onUp(),
          child: CustomPaint(
            size: Size(vw, vh),
            painter: _CanvasPainter(
              base: _baseUi,
              result: inCompare ? _resultUi : null,
              strokes: _strokes,
              current: _current,
              currentBrush: widget.brushSize,
              splitX: _splitX,
              scale: _scale,
              offX: _offX,
              offY: _offY,
              repaint: _strokes.length * 1000 + (_current?.length ?? 0),
            ),
          ),
        );
      },
    );
  }
}

class _CanvasPainter extends CustomPainter {
  final ui.Image? base;
  final ui.Image? result;
  final List<Stroke> strokes;
  final List<Offset>? current;
  final double currentBrush;
  final double splitX;
  final double scale, offX, offY;
  final int repaint;

  _CanvasPainter({
    required this.base,
    required this.result,
    required this.strokes,
    required this.current,
    required this.currentBrush,
    required this.splitX,
    required this.scale,
    required this.offX,
    required this.offY,
    required this.repaint,
  });

  static final Paint _imgPaint = Paint()..filterQuality = FilterQuality.medium;

  @override
  void paint(Canvas c, Size size) {
    final b = base;
    if (b == null) return;
    final w = b.width.toDouble();
    final h = b.height.toDouble();

    c.save();
    c.translate(offX, offY);
    c.scale(scale);

    if (result != null) {
      final sx = splitX * w;
      c.save();
      c.clipRect(Rect.fromLTRB(0, 0, sx, h));
      c.drawImage(b, Offset.zero, _imgPaint);
      _drawMask(c);
      c.restore();

      c.save();
      c.clipRect(Rect.fromLTRB(sx, 0, w, h));
      c.drawImage(result!, Offset.zero, _imgPaint);
      c.restore();

      c.drawLine(
        Offset(sx, 0),
        Offset(sx, h),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 2
          ..isAntiAlias = true,
      );
    } else {
      c.drawImage(b, Offset.zero, _imgPaint);
      _drawMask(c);
    }
    c.restore();

    if (result != null) _drawHandle(c, w, h);
  }

  void _drawMask(Canvas c) {
    // 原生：白色笔迹 bitmap 以 alpha=120 叠加
    const maskColor = Color.fromARGB(120, 255, 255, 255);
    for (final s in strokes) {
      _drawStroke(c, s.points, s.brush, maskColor);
    }
    final cur = current;
    if (cur != null && cur.isNotEmpty) {
      _drawStroke(c, cur, currentBrush, maskColor);
    }
  }

  void _drawStroke(Canvas c, List<Offset> pts, double brush, Color color) {
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      c.drawCircle(
        pts[0],
        brush / 2,
        Paint()
          ..color = color
          ..isAntiAlias = true,
      );
      return;
    }
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (int i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    c.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = brush
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true,
    );
  }

  void _drawHandle(Canvas c, double w, double h) {
    final hx = offX + splitX * w * scale;
    final hy = offY + (h * scale) / 2;
    const hr = PaintCanvasState._handleR;

    c.drawCircle(
      Offset(hx, hy),
      hr,
      Paint()
        ..color = const Color(0xFF0E3B2D)
        ..isAntiAlias = true,
    );

    final arrow = Paint()
      ..color = Colors.white
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    c.drawLine(Offset(hx - 7, hy - 5), Offset(hx - 2, hy), arrow);
    c.drawLine(Offset(hx - 7, hy + 5), Offset(hx - 2, hy), arrow);
    c.drawLine(Offset(hx + 7, hy - 5), Offset(hx + 2, hy), arrow);
    c.drawLine(Offset(hx + 7, hy + 5), Offset(hx + 2, hy), arrow);

    c.drawCircle(
      Offset(hx, hy),
      hr,
      Paint()
        ..color = const Color(0xFF0E3B2D)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter old) =>
      old.base != base ||
      old.result != result ||
      old.repaint != repaint ||
      old.splitX != splitX ||
      old.scale != scale ||
      old.offX != offX ||
      old.offY != offY ||
      old.currentBrush != currentBrush;
}
