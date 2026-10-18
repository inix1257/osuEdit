import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

void main() {
  test('linear path is trimmed to expected length', () {
    final p = SliderPath.fromControlPoints(
        CurveType.linear, const [Vec2(0, 0), Vec2(100, 0), Vec2(100, 100)], 150);
    expect(p.distance, 150);
    expect(p.tail.x, closeTo(100, 1e-9));
    expect(p.tail.y, closeTo(50, 1e-9));
    expect(p.positionAt(0.5).x, closeTo(75, 1e-9));
  });

  test('path shorter than expected is extended straight', () {
    final p = SliderPath.fromControlPoints(
        CurveType.linear, const [Vec2(0, 0), Vec2(100, 0)], 140);
    expect(p.tail.x, closeTo(140, 1e-9));
    expect(p.tail.y, closeTo(0, 1e-9));
  });

  test('perfect circle passes through all three points on the circle', () {
    const a = Vec2(0, 0), b = Vec2(50, 50), c = Vec2(100, 0);
    // Half circle of radius 50 → length 50π.
    final p = SliderPath.fromControlPoints(
        CurveType.perfectCircle, const [a, b, c], 50 * math.pi);
    final centre = const Vec2(50, 0);
    for (final v in p.vertices) {
      expect(v.distanceTo(centre), closeTo(50, 0.2));
    }
    expect(p.positionAt(0.5).distanceTo(b), lessThan(1));
    expect(p.tail.distanceTo(c), lessThan(1));
  });

  test('perfect circle arc goes through the middle point side', () {
    // Same endpoints, middle point below: the arc must bulge downward.
    final p = SliderPath.fromControlPoints(CurveType.perfectCircle,
        const [Vec2(0, 0), Vec2(50, -50), Vec2(100, 0)], 50 * math.pi);
    expect(p.positionAt(0.5).y, closeTo(-50, 1));
  });

  test('collinear perfect circle falls back to a straight-ish path', () {
    final p = SliderPath.fromControlPoints(CurveType.perfectCircle,
        const [Vec2(0, 0), Vec2(50, 0), Vec2(100, 0)], 100);
    expect(p.tail.x, closeTo(100, 1e-6));
    expect(p.tail.y, closeTo(0, 1e-6));
  });

  test('bezier endpoints and red anchors', () {
    final p = SliderPath.fromControlPoints(
        CurveType.bezier,
        const [Vec2(0, 0), Vec2(50, 100), Vec2(100, 0), Vec2(100, 0), Vec2(200, 0)],
        0);
    expect(p.head, const Vec2(0, 0));
    expect(p.tail, const Vec2(200, 0));
    // The anchor point (100,0) is a sharp corner that lies on the path.
    expect(p.vertices.contains(const Vec2(100, 0)), isTrue);
    // A quadratic bezier peak with control y=100 reaches y=50.
    final maxY = p.vertices.map((v) => v.y).reduce(math.max);
    expect(maxY, closeTo(50, 0.5));
  });

  test('catmull passes through its control points', () {
    const pts = [Vec2(0, 0), Vec2(50, 50), Vec2(100, 0)];
    final p = SliderPath.fromControlPoints(CurveType.catmull, pts, 0);
    expect(p.vertices.contains(const Vec2(50, 50)), isTrue);
    expect(p.tail, const Vec2(100, 0));
  });

  test('ball position handles repeats', () {
    final p = SliderPath.fromControlPoints(
        CurveType.linear, const [Vec2(0, 0), Vec2(100, 0)], 100);
    expect(p.ballPositionAt(0, 0, 1000, 2).x, 0);
    expect(p.ballPositionAt(500, 0, 1000, 2).x, closeTo(50, 1e-9));
    expect(p.ballPositionAt(1000, 0, 1000, 2).x, closeTo(100, 1e-9));
    expect(p.ballPositionAt(1500, 0, 1000, 2).x, closeTo(50, 1e-9));
    expect(p.ballPositionAt(2000, 0, 1000, 2).x, closeTo(0, 1e-9));
  });

  test('slider translate moves control points too', () {
    const s = SliderObject(
      position: Vec2(0, 0),
      time: 0,
      curveType: CurveType.linear,
      controlPoints: [Vec2(100, 0)],
      length: 100,
    );
    final m = s.translated(const Vec2(5, 5));
    expect(m.position, const Vec2(5, 5));
    expect(m.controlPoints, [const Vec2(105, 5)]);
  });
}
