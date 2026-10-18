import 'dart:math' as math;

import '../math/vec2.dart';

/// Converts slider control points into polylines.
///
/// Algorithms follow the behaviour of osu! (see osu-framework's
/// `PathApproximator`, MIT) so that rendered shapes match the game:
/// adaptive bezier subdivision, centripetal-less Catmull-Rom with 50 steps
/// per segment, and circular arcs through exactly three points.
abstract final class PathApproximator {
  static const bezierTolerance = 0.25;
  static const circularArcTolerance = 0.1;
  static const catmullDetail = 50;
  static const _maxBezierDepth = 14;

  static List<Vec2> linear(List<Vec2> points) => List.of(points);

  /// Adaptive subdivision until each piece's control polygon is flat enough
  /// (second differences under tolerance). Emits the polygon of flat pieces.
  static List<Vec2> bezier(List<Vec2> points) {
    if (points.length < 2) return List.of(points);
    if (points.length == 2) return List.of(points);
    final out = <Vec2>[];
    _bezierRec(points, out, 0);
    out.add(points.last);
    return out;
  }

  static void _bezierRec(List<Vec2> pts, List<Vec2> out, int depth) {
    if (depth >= _maxBezierDepth || _isFlatEnough(pts)) {
      // Emit the polygon except its last point (the next piece starts there).
      for (var i = 0; i < pts.length - 1; i++) {
        out.add(pts[i]);
      }
      return;
    }
    final (left, right) = _subdivide(pts);
    _bezierRec(left, out, depth + 1);
    _bezierRec(right, out, depth + 1);
  }

  static bool _isFlatEnough(List<Vec2> pts) {
    const limit = bezierTolerance * bezierTolerance * 4;
    for (var i = 1; i < pts.length - 1; i++) {
      final d = pts[i - 1] - pts[i] * 2 + pts[i + 1];
      if (d.lengthSquared > limit) return false;
    }
    return true;
  }

  /// de Casteljau split at t = 0.5.
  static (List<Vec2>, List<Vec2>) _subdivide(List<Vec2> pts) {
    final n = pts.length;
    final mid = List.of(pts);
    final left = List<Vec2>.filled(n, Vec2.zero);
    final right = List<Vec2>.filled(n, Vec2.zero);
    for (var i = 0; i < n; i++) {
      left[i] = mid[0];
      right[n - i - 1] = mid[n - i - 1];
      for (var j = 0; j < n - i - 1; j++) {
        mid[j] = (mid[j] + mid[j + 1]) * 0.5;
      }
    }
    return (left, right);
  }

  static List<Vec2> catmull(List<Vec2> points) {
    final n = points.length;
    if (n < 2) return List.of(points);
    final out = <Vec2>[];
    for (var i = 0; i < n - 1; i++) {
      final v1 = i > 0 ? points[i - 1] : points[i];
      final v2 = points[i];
      final v3 = i < n - 1 ? points[i + 1] : v2 * 2 - v1;
      final v4 = i < n - 2 ? points[i + 2] : v3 * 2 - v2;
      for (var c = 0; c < catmullDetail; c++) {
        out.add(_catmullPoint(v1, v2, v3, v4, c / catmullDetail));
      }
    }
    out.add(points.last);
    return out;
  }

  static Vec2 _catmullPoint(Vec2 v1, Vec2 v2, Vec2 v3, Vec2 v4, double t) {
    final t2 = t * t, t3 = t2 * t;
    double f(double a, double b, double c, double d) =>
        0.5 *
        (2 * b +
            (-a + c) * t +
            (2 * a - 5 * b + 4 * c - d) * t2 +
            (-a + 3 * b - 3 * c + d) * t3);
    return Vec2(f(v1.x, v2.x, v3.x, v4.x), f(v1.y, v2.y, v3.y, v4.y));
  }

  /// Circular arc through exactly 3 points. Returns null when the points are
  /// (nearly) collinear; callers then fall back to bezier like osu! does.
  static List<Vec2>? circularArc(List<Vec2> points) {
    if (points.length != 3) return null;
    final a = points[0], b = points[1], c = points[2];

    final d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y));
    if (d.abs() < 1e-3) return null;

    final aSq = a.lengthSquared, bSq = b.lengthSquared, cSq = c.lengthSquared;
    final centre = Vec2(
      (aSq * (b.y - c.y) + bSq * (c.y - a.y) + cSq * (a.y - b.y)) / d,
      (aSq * (c.x - b.x) + bSq * (a.x - c.x) + cSq * (b.x - a.x)) / d,
    );
    final radius = a.distanceTo(centre);

    final thetaStart = math.atan2(a.y - centre.y, a.x - centre.x);
    var thetaEnd = math.atan2(c.y - centre.y, c.x - centre.x);
    while (thetaEnd < thetaStart) {
      thetaEnd += 2 * math.pi;
    }
    var dir = 1.0;
    var range = thetaEnd - thetaStart;

    // If B lies on the other side of AC, the arc goes the other way round.
    final ac = c - a;
    final ortho = Vec2(ac.y, -ac.x);
    if (ortho.dot(b - a) < 0) {
      dir = -1;
      range = 2 * math.pi - range;
    }

    final int amount;
    if (2 * radius <= circularArcTolerance) {
      amount = 2;
    } else {
      amount = math.max(
          2,
          (range / (2 * math.acos(1 - circularArcTolerance / radius)))
              .ceil());
    }
    if (amount > 10000) return null; // absurd radius; treat as degenerate

    return [
      for (var i = 0; i < amount; i++)
        () {
          final theta = thetaStart + dir * (i / (amount - 1)) * range;
          return centre + Vec2(math.cos(theta), math.sin(theta)) * radius;
        }()
    ];
  }
}
