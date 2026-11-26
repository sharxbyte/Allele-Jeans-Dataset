import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Finger signature. [controller] exposes the strokes and a PNG export.
class SignatureController extends ChangeNotifier {
  final List<List<Offset>> strokes = [];
  Size _size = const Size(600, 200);

  bool get isEmpty => strokes.every((s) => s.length < 2);

  void startStroke(Offset o) {
    strokes.add([o]);
    notifyListeners();
  }

  void extendStroke(Offset o) {
    if (strokes.isEmpty) return startStroke(o);
    strokes.last.add(o);
    notifyListeners();
  }

  void clear() {
    strokes.clear();
    notifyListeners();
  }

  Future<Uint8List> toPng() async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(Offset.zero & _size, Paint()..color = Colors.white);
    _SignaturePainter(strokes, Colors.black).paint(c, _size);
    final image = await rec.endRecording().toImage(_size.width.round(), _size.height.round());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }
}

class SignaturePad extends StatelessWidget {
  final SignatureController controller;
  const SignaturePad({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Signature area. Sign with your finger.',
      child: Container(
        height: 160,
        decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.black26), borderRadius: BorderRadius.circular(8)),
        child: LayoutBuilder(builder: (context, box) {
          controller._size = Size(box.maxWidth, box.maxHeight);
          return GestureDetector(
            onPanStart: (d) => controller.startStroke(d.localPosition),
            onPanUpdate: (d) => controller.extendStroke(d.localPosition),
            child: AnimatedBuilder(
              animation: controller,
              builder: (_, _) => CustomPaint(painter: _SignaturePainter(controller.strokes, Colors.black), size: Size.infinite),
            ),
          );
        }),
      ),
    );
  }
}

class _SignaturePainter extends CustomPainter {
  final List<List<Offset>> strokes;
  final Color color;
  _SignaturePainter(this.strokes, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final s in strokes) {
      if (s.length < 2) continue;
      final path = Path()..moveTo(s.first.dx, s.first.dy);
      for (final o in s.skip(1)) {
        path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(covariant _SignaturePainter old) => true;
}
