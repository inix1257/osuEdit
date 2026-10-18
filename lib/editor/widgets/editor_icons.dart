import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Editor-specific glyphs that Material icons don't cover well.
enum EditorGlyph { slider, spinner, whistle, finish }

/// Paints an [EditorGlyph] in a square of [size], tinted [color], styled to
/// sit next to outlined Material icons (24-unit grid, ~2-unit strokes).
class EditorGlyphIcon extends StatelessWidget {
  final EditorGlyph glyph;
  final double size;
  final Color color;

  const EditorGlyphIcon(this.glyph, {super.key, this.size = 24, required this.color});

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _GlyphPainter(glyph, color)),
      );
}

class _GlyphPainter extends CustomPainter {
  final EditorGlyph glyph;
  final Color color;
  _GlyphPainter(this.glyph, this.color);

  Paint get _stroke => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  Paint get _fill => Paint()..color = color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    switch (glyph) {
      case EditorGlyph.slider:
        _slider(canvas);
      case EditorGlyph.spinner:
        _spinner(canvas);
      case EditorGlyph.whistle:
        _whistle(canvas);
      case EditorGlyph.finish:
        _finish(canvas);
    }
  }

  /// Straight slider on the diagonal: translucent capsule body, filled head
  /// circle at the start, hollow tail ring at the end.
  void _slider(Canvas canvas) {
    canvas.save();
    canvas.translate(12, 12);
    canvas.rotate(-math.pi / 4);
    const half = 7.0, r = 4.6;
    final body = RRect.fromLTRBR(-half - r, -r, half + r, r, const Radius.circular(r));
    canvas.drawRRect(body, Paint()..color = color.withValues(alpha: 0.28));
    canvas.drawRRect(body, _stroke..strokeWidth = 1.4);
    // Tail: hollow ring.
    canvas.drawCircle(const Offset(half, 0), 2.2, _stroke..strokeWidth = 1.6);
    // Head: solid circle filling the start cap.
    canvas.drawCircle(const Offset(-half, 0), r, _fill);
    canvas.restore();
  }

  /// Two chasing arrows around a circle.
  void _spinner(Canvas canvas) {
    const c = Offset(12, 12), r = 8.0, sweep = 2.0;
    final rect = Rect.fromCircle(center: c, radius: r);
    for (final start in [-math.pi / 2 - 0.3, math.pi / 2 - 0.3]) {
      canvas.drawArc(rect, start, sweep, false, _stroke);
      // Arrowhead at the arc's end, pointing along the tangent (clockwise).
      final a = start + sweep;
      final tip = c + Offset(math.cos(a), math.sin(a)) * r;
      final tangent = Offset(-math.sin(a), math.cos(a));
      final normal = Offset(math.cos(a), math.sin(a));
      final head = Path()
        ..moveTo(tip.dx + tangent.dx * 2.6, tip.dy + tangent.dy * 2.6)
        ..lineTo(tip.dx - tangent.dx * 1.2 + normal.dx * 2.6,
            tip.dy - tangent.dy * 1.2 + normal.dy * 2.6)
        ..lineTo(tip.dx - tangent.dx * 1.2 - normal.dx * 2.6,
            tip.dy - tangent.dy * 1.2 - normal.dy * 2.6)
        ..close();
      canvas.drawPath(head, _fill);
    }
  }

  /// Referee whistle: round chamber with a mouthpiece, the pea inside, and a
  /// lanyard ring.
  void _whistle(Canvas canvas) {
    const centre = Offset(9, 15);
    final chamber = Path()..addOval(Rect.fromCircle(center: centre, radius: 6));
    final mouth = Path()
      ..addRRect(RRect.fromLTRBR(9, 8, 22, 12.5, const Radius.circular(1.2)));
    canvas.drawPath(Path.combine(PathOperation.union, chamber, mouth), _stroke);
    // Pea.
    canvas.drawCircle(centre, 2, _fill);
    // Lanyard ring.
    canvas.drawCircle(const Offset(3.4, 7.6), 1.8, _stroke..strokeWidth = 1.5);
  }

  /// Crash cymbal on a stand: tilted plate with a bell, tripod below.
  void _finish(Canvas canvas) {
    canvas.save();
    canvas.translate(12, 8.5);
    canvas.rotate(-0.18);
    final plate = Path()
      ..moveTo(-10, 1.2)
      ..quadraticBezierTo(0, -4.2, 10, 1.2)
      ..quadraticBezierTo(0, 4.2, -10, 1.2)
      ..close();
    canvas.drawPath(plate, Paint()..color = color.withValues(alpha: 0.28));
    canvas.drawPath(plate, _stroke..strokeWidth = 1.8);
    // Bell.
    canvas.drawPath(
        Path()
          ..moveTo(-2.6, -1.2)
          ..quadraticBezierTo(0, -5.4, 2.6, -1.2)
          ..close(),
        _fill);
    canvas.restore();
    // Stand + tripod.
    final s = _stroke..strokeWidth = 1.7;
    canvas.drawLine(const Offset(12, 10.5), const Offset(12, 21), s);
    canvas.drawLine(const Offset(12, 17), const Offset(7.5, 21.5), s);
    canvas.drawLine(const Offset(12, 17), const Offset(16.5, 21.5), s);
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.glyph != glyph || old.color != color;
}
