import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

/// The stroke's largest distance from the fitted path (as osu! draws it).
double _worstDistance(List<Vec2> stroke, List<PathPoint> fitted) {
  final all = SliderShape.encode(fitted);
  final type = fitted.length == 2 ? CurveType.linear : CurveType.bezier;
  final path = SliderPath.fromControlPoints(type, all, 0);
  double toSegment(Vec2 p, Vec2 a, Vec2 b) {
    final ab = b - a, ap = p - a;
    final len2 = ab.lengthSquared;
    final t = len2 == 0 ? 0.0 : ((ab.x * ap.x + ab.y * ap.y) / len2).clamp(0.0, 1.0);
    return (a + ab * t).distanceTo(p);
  }

  final v = path.vertices;
  var worst = 0.0;
  for (final p in stroke) {
    var best = double.infinity;
    for (var i = 1; i < v.length; i++) {
      best = math.min(best, toSegment(p, v[i - 1], v[i]));
    }
    worst = math.max(worst, best);
  }
  return worst;
}

void main() {
  test('a straight stroke becomes a two-point line', () {
    final stroke = [for (var i = 0; i <= 60; i++) Vec2(100 + i * 3.0, 200 + (i.isEven ? 0.6 : -0.6))];
    final fit = FreehandFit.fit(stroke)!;
    expect(fit, hasLength(2));
    expect(fit.first.position.distanceTo(const Vec2(100, 200)), lessThanOrEqualTo(1));
    expect(fit.last.position.distanceTo(const Vec2(280, 200)), lessThanOrEqualTo(1));
  });

  test('a curved stroke is followed within the tolerance by bezier pieces', () {
    final stroke = [
      for (var i = 0; i <= 120; i++)
        Vec2(256 + 120 * math.cos(math.pi * i / 120), 192 + 80 * math.sin(math.pi * i / 120)),
    ];
    final fit = FreehandFit.fit(stroke, tolerance: 4)!;
    expect(fit.length, greaterThan(3));
    expect(fit.first.position, stroke.first.roundToInt());
    expect(fit.last.position, stroke.last.roundToInt());
    expect(fit.first.red || fit.last.red, isFalse);
    // Whole pixels plus the tolerance (and the flattening of the path).
    expect(_worstDistance(stroke, fit), lessThan(4 + 1.5));
  });

  test('a sharp corner splits the path with a red anchor there', () {
    final stroke = [
      for (var i = 0; i <= 40; i++) Vec2(100 + i * 3.0, 100),
      for (var i = 1; i <= 40; i++) Vec2(220, 100 + i * 3.0),
    ];
    final fit = FreehandFit.fit(stroke)!;
    final reds = [for (final p in fit) if (p.red) p.position];
    expect(reds, hasLength(1));
    expect(reds.single.distanceTo(const Vec2(220, 100)), lessThan(4));
    expect(_worstDistance(stroke, fit), lessThan(5));
  });

  test('straight runs between corners are handle-free lines', () {
    // A zigzag: three straight legs, two corners.
    final stroke = [
      for (var i = 0; i <= 40; i++) Vec2(100 + i * 3.0, 100),
      for (var i = 1; i <= 40; i++) Vec2(220, 100 + i * 3.0),
      for (var i = 1; i <= 40; i++) Vec2(220 + i * 3.0, 220),
    ];
    final fit = FreehandFit.fit(stroke)!;
    // head, 2 corners, tail: no handles at all.
    expect(fit, hasLength(4));
    expect([for (final p in fit) p.red], [false, true, true, false]);
    expect(_worstDistance(stroke, fit), lessThan(5));
  });

  test('a smooth arc is not cut into needless pieces', () {
    final stroke = [
      for (var i = 0; i <= 120; i++) Vec2(256 + 100 * math.cos(math.pi * i / 120), 250 - 100 * math.sin(math.pi * i / 120)),
    ];
    final fit = FreehandFit.fit(stroke, tolerance: 4)!;
    final reds = fit.where((p) => p.red).length;
    expect(reds, lessThanOrEqualTo(2), reason: '${fit.length} points');
    expect(_worstDistance(stroke, fit), lessThan(4 + 1.5));
  });

  test('a stroke that barely moves is no slider', () {
    expect(FreehandFit.fit([const Vec2(10, 10), const Vec2(12, 11), const Vec2(13, 10)]), isNull);
    expect(FreehandFit.fit(const []), isNull);
  });

  test('an S-shaped stroke keeps its control points near the stroke', () {
    final stroke = [for (var i = 0; i <= 40; i++) Vec2(110 + 320 * i / 40, 190 - 102 * math.sin(2 * math.pi * i / 40))];
    final fit = FreehandFit.fit(stroke)!;
    for (final p in fit) {
      expect(p.position.y, inInclusiveRange(88 - 12, 292 + 12), reason: '${p.position}');
      expect(p.position.x, inInclusiveRange(110 - 12, 430 + 12), reason: '${p.position}');
    }
    expect(_worstDistance(stroke, fit), lessThan(5.5));
  });
}
