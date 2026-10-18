import 'dart:math' as math;

import '../math/vec2.dart';
import 'slider_shape.dart';

/// Turns a stroke drawn with the finger into a slider path: cubic bezier
/// pieces that stay within [FreehandFit.fit]'s tolerance of the stroke,
/// split at sharp corners. The pieces are joined by red anchors, so the
/// result is a plain bezier path both osu!stable and osu!lazer read (unlike
/// lazer's own freehand tool, which makes B-splines only lazer can read).
///
/// Curve fitting follows Philip J. Schneider, "An Algorithm for
/// Automatically Fitting Digitized Curves" (Graphics Gems, 1990):
/// chord-length parameters, a least-squares cubic for fixed end tangents,
/// Newton–Raphson reparameterisation, and splitting at the worst point.
/// Straight runs become two-point line pieces, and neighbouring pieces that a
/// single cubic can replace are merged, to keep the node count low.
abstract final class FreehandFit {
  /// Points closer than this to the previous kept one are dropped.
  static const minSpacing = 3.0;

  /// How far (along the stroke) on each side the corner test looks.
  static const cornerReach = 14.0;

  /// The path through [stroke] (osu!pixels, in drawing order) as editable
  /// points, head first: interior red points split bezier pieces. Points
  /// are whole osu!pixels. Null when the stroke is too short to be a slider.
  ///
  /// [tolerance] is the largest distance (osu!pixels) the path may stray
  /// from the stroke; a turn sharper than [cornerDegrees] over
  /// [cornerReach] on both sides becomes a corner.
  static List<PathPoint>? fit(List<Vec2> stroke, {double tolerance = 4, double cornerDegrees = 70}) {
    final pts = _resample(stroke);
    if (pts.length < 2 || _length(pts) < minSpacing * 3) return null;

    // Nearly straight: one line.
    if (_maxDeviation(pts, 0, pts.length - 1) <= tolerance) {
      return _whole([PathPoint(pts.first), PathPoint(pts.last)]);
    }

    final corners = _corners(pts, cornerDegrees);
    final out = <PathPoint>[PathPoint(pts.first)];
    for (var k = 0; k < corners.length - 1; k++) {
      final a = corners[k], b = corners[k + 1];
      final run = pts.sublist(a, b + 1);
      final pieces = <_Piece>[];
      if (run.length < 3 || _maxDeviation(run, 0, run.length - 1) <= tolerance) {
        // A straight run: a two-point piece (a line) needs no handles.
        pieces.add(_Piece([run.first, run.last], 0, run.length - 1));
      } else {
        _fitCubic(run, 0, run.length - 1, _leftTangent(run, 0), _rightTangent(run, run.length - 1), tolerance, pieces);
        _mergePieces(run, pieces, tolerance);
      }
      for (final piece in pieces) {
        final c = piece.controls;
        for (var i = 1; i < c.length - 1; i++) {
          out.add(PathPoint(c[i]));
        }
        out.add(PathPoint(c.last, red: true));
      }
    }
    // The tail is no segment boundary.
    out[out.length - 1] = PathPoint(out.last.position);
    return _whole(out);
  }

  /// Rounds to whole osu!pixels and drops points that collapse onto the one
  /// before (a red one passes its red on).
  static List<PathPoint> _whole(List<PathPoint> pts) {
    final out = <PathPoint>[];
    for (final p in pts) {
      final r = p.position.roundToInt();
      if (out.isNotEmpty && out.last.position == r) {
        if (p.red && out.length > 1) out[out.length - 1] = PathPoint(r, red: true);
        continue;
      }
      out.add(PathPoint(r, red: p.red));
    }
    if (out.isNotEmpty) out[out.length - 1] = PathPoint(out.last.position);
    return out;
  }

  static List<Vec2> _resample(List<Vec2> stroke) {
    final out = <Vec2>[];
    for (final p in stroke) {
      if (out.isEmpty || p.distanceTo(out.last) >= minSpacing) out.add(p);
    }
    if (stroke.isNotEmpty && out.isNotEmpty && out.last != stroke.last && stroke.last.distanceTo(out.last) > 0.5) {
      out.add(stroke.last);
    }
    return out;
  }

  static double _length(List<Vec2> pts) {
    var l = 0.0;
    for (var i = 1; i < pts.length; i++) {
      l += pts[i].distanceTo(pts[i - 1]);
    }
    return l;
  }

  /// Largest distance of `pts[first..last]` from the chord between them.
  static double _maxDeviation(List<Vec2> pts, int first, int last) {
    final a = pts[first], b = pts[last];
    final ab = b - a;
    final len = ab.length;
    var worst = 0.0;
    for (var i = first + 1; i < last; i++) {
      final ap = pts[i] - a;
      final d = len == 0 ? ap.length : (ab.x * ap.y - ab.y * ap.x).abs() / len;
      if (d > worst) worst = d;
    }
    return worst;
  }

  /// Indices of the stroke's ends and its corners (local maxima of the
  /// turn angle, measured [cornerReach] along the stroke on each side).
  static List<int> _corners(List<Vec2> pts, double cornerDegrees) {
    final n = pts.length;
    final cum = List<double>.filled(n, 0);
    for (var i = 1; i < n; i++) {
      cum[i] = cum[i - 1] + pts[i].distanceTo(pts[i - 1]);
    }
    final turn = List<double>.filled(n, 0);
    for (var i = 1; i < n - 1; i++) {
      var a = i, b = i;
      while (a > 0 && cum[i] - cum[a] < cornerReach) {
        a--;
      }
      while (b < n - 1 && cum[b] - cum[i] < cornerReach) {
        b++;
      }
      final d1 = pts[i] - pts[a], d2 = pts[b] - pts[i];
      if (d1.length == 0 || d2.length == 0) continue;
      final cos = (d1.x * d2.x + d1.y * d2.y) / (d1.length * d2.length);
      turn[i] = math.acos(cos.clamp(-1.0, 1.0)) * 180 / math.pi;
    }
    final out = [0];
    for (var i = 1; i < n - 1; i++) {
      if (turn[i] < cornerDegrees) continue;
      // Only the sharpest point of a turn, and not right next to the last corner.
      var peak = true;
      for (var j = i - 1; j >= 0 && cum[i] - cum[j] < cornerReach; j--) {
        if (turn[j] > turn[i]) peak = false;
      }
      for (var j = i + 1; j < n && cum[j] - cum[i] < cornerReach; j++) {
        if (turn[j] >= turn[i]) peak = false;
      }
      if (peak && cum[i] - cum[out.last] >= cornerReach && cum[n - 1] - cum[i] >= cornerReach) out.add(i);
    }
    out.add(n - 1);
    return out;
  }

  static Vec2 _unit(Vec2 v) => v.length == 0 ? Vec2.zero : v / v.length;

  static Vec2 _leftTangent(List<Vec2> pts, int i) => _unit(pts[math.min(i + 2, pts.length - 1)] - pts[i]);

  static Vec2 _rightTangent(List<Vec2> pts, int i) => _unit(pts[math.max(i - 2, 0)] - pts[i]);

  /// Joins neighbouring cubic pieces into one wherever a single cubic that
  /// keeps the outer end tangents still fits the stroke between them, so a
  /// needless split (and its red anchor) disappears.
  static void _mergePieces(List<Vec2> pts, List<_Piece> pieces, double tolerance) {
    var i = 0;
    while (i < pieces.length - 1) {
      final a = pieces[i], b = pieces[i + 1];
      if (a.controls.length != 4 || b.controls.length != 4) {
        i++;
        continue;
      }
      final t1 = _unit(a.controls[1] - a.controls[0]);
      final t2 = _unit(b.controls[2] - b.controls[3]);
      final bez = _tryFit(pts, a.first, b.last, t1, t2, tolerance);
      if (bez == null) {
        i++;
        continue;
      }
      pieces[i] = _Piece(bez, a.first, b.last);
      pieces.removeAt(i + 1);
      // The merged piece may join with its left neighbour too.
      if (i > 0) i--;
    }
  }

  /// A single cubic through `pts[first..last]` within [tolerance] (and with
  /// handles near the stroke), or null.
  static List<Vec2>? _tryFit(List<Vec2> pts, int first, int last, Vec2 t1, Vec2 t2, double tolerance) {
    if (last - first < 2 || t1.length == 0 || t2.length == 0) return null;
    final near = _controlsNear(pts, first, last, tolerance, strict: true);
    var u = _chordParams(pts, first, last);
    var bez = _generate(pts, first, last, u, t1, t2);
    var (err, _) = _maxError(pts, first, last, bez, u);
    if (err < tolerance && near(bez)) return bez;
    if (err >= tolerance * 4) return null;
    for (var i = 0; i < 4; i++) {
      u = _reparameterize(pts, first, last, u, bez);
      bez = _generate(pts, first, last, u, t1, t2);
      (err, _) = _maxError(pts, first, last, bez, u);
      if (err < tolerance && near(bez)) return bez;
    }
    return null;
  }

  static void _fitCubic(List<Vec2> pts, int first, int last, Vec2 t1, Vec2 t2, double tolerance, List<_Piece> out,
      [int depth = 0]) {
    if (last - first == 1 || depth > 12) {
      final d = pts[first].distanceTo(pts[last]) / 3;
      out.add(_Piece([pts[first], pts[first] + t1 * d, pts[last] + t2 * d, pts[last]], first, last));
      return;
    }
    var u = _chordParams(pts, first, last);
    var bez = _generate(pts, first, last, u, t1, t2);
    var (err, split) = _maxError(pts, first, last, bez, u);
    // A close fit whose control points fly far off the stroke (one cubic
    // swinging through an S) is split too: its handles would be unusable
    // and could leave the playfield.
    final near = _controlsNear(pts, first, last, tolerance);
    if (err < tolerance && near(bez)) {
      out.add(_Piece(bez, first, last));
      return;
    }
    if (err < tolerance * 4) {
      for (var i = 0; i < 4; i++) {
        u = _reparameterize(pts, first, last, u, bez);
        bez = _generate(pts, first, last, u, t1, t2);
        (err, split) = _maxError(pts, first, last, bez, u);
        if (err < tolerance && near(bez)) {
          out.add(_Piece(bez, first, last));
          return;
        }
      }
    }
    if (err < tolerance) split = (first + last) ~/ 2;
    split = split.clamp(first + 1, last - 1);
    final center = _unit(pts[split - 1] - pts[split + 1]);
    _fitCubic(pts, first, split, t1, center, tolerance, out, depth + 1);
    _fitCubic(pts, split, last, -center, t2, tolerance, out, depth + 1);
  }

  /// Whether a cubic's control points stay near the bounds of
  /// `pts[first..last]`.
  static bool Function(List<Vec2>) _controlsNear(List<Vec2> pts, int first, int last, double tolerance,
      {bool strict = false}) {
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    for (var i = first; i <= last; i++) {
      minX = math.min(minX, pts[i].x);
      maxX = math.max(maxX, pts[i].x);
      minY = math.min(minY, pts[i].y);
      maxY = math.max(maxY, pts[i].y);
    }
    // A cubic's handles naturally reach past a bend (a third of its
    // bulge or so): allow that much, scaled to the piece.
    // A merge gets no such allowance: it may only drop a split, not add swing.
    final pad = strict ? tolerance * 3 : math.max(tolerance * 3, 0.35 * math.max(maxX - minX, maxY - minY));
    bool inside(Vec2 p) => p.x >= minX - pad && p.x <= maxX + pad && p.y >= minY - pad && p.y <= maxY + pad;
    return (bez) => inside(bez[1]) && inside(bez[2]);
  }

  static List<double> _chordParams(List<Vec2> pts, int first, int last) {
    final u = <double>[0];
    for (var i = first + 1; i <= last; i++) {
      u.add(u.last + pts[i].distanceTo(pts[i - 1]));
    }
    final total = u.last;
    return [for (final x in u) total == 0 ? 0.0 : x / total];
  }

  /// The least-squares cubic through `pts[first..last]` with end tangents
  /// [t1] / [t2] at parameters [u].
  static List<Vec2> _generate(List<Vec2> pts, int first, int last, List<double> u, Vec2 t1, Vec2 t2) {
    final p0 = pts[first], p3 = pts[last];
    var c00 = 0.0, c01 = 0.0, c11 = 0.0, x0 = 0.0, x1 = 0.0;
    for (var i = 0; i <= last - first; i++) {
      final t = u[i], mt = 1 - t;
      final b0 = mt * mt * mt, b1 = 3 * t * mt * mt, b2 = 3 * t * t * mt, b3 = t * t * t;
      final a1 = t1 * b1, a2 = t2 * b2;
      c00 += _dot(a1, a1);
      c01 += _dot(a1, a2);
      c11 += _dot(a2, a2);
      final tmp = pts[first + i] - (p0 * (b0 + b1) + p3 * (b2 + b3));
      x0 += _dot(a1, tmp);
      x1 += _dot(a2, tmp);
    }
    final det = c00 * c11 - c01 * c01;
    final segLen = p0.distanceTo(p3);
    var alpha1 = det.abs() < 1e-12 ? 0.0 : (x0 * c11 - x1 * c01) / det;
    var alpha2 = det.abs() < 1e-12 ? 0.0 : (c00 * x1 - c01 * x0) / det;
    // Degenerate or wild solutions: the Wu/Barsky heuristic.
    final eps = 1e-6 * segLen;
    if (alpha1 < eps || alpha2 < eps || alpha1 > segLen * 2 || alpha2 > segLen * 2) {
      alpha1 = alpha2 = segLen / 3;
    }
    return [p0, p0 + t1 * alpha1, p3 + t2 * alpha2, p3];
  }

  static double _dot(Vec2 a, Vec2 b) => a.x * b.x + a.y * b.y;

  static Vec2 _bezier(List<Vec2> c, double t) {
    final mt = 1 - t;
    return c[0] * (mt * mt * mt) + c[1] * (3 * mt * mt * t) + c[2] * (3 * mt * t * t) + c[3] * (t * t * t);
  }

  static (double, int) _maxError(List<Vec2> pts, int first, int last, List<Vec2> bez, List<double> u) {
    var worst = 0.0;
    var at = (first + last) ~/ 2;
    for (var i = first + 1; i < last; i++) {
      final d = _bezier(bez, u[i - first]).distanceTo(pts[i]);
      if (d > worst) {
        worst = d;
        at = i;
      }
    }
    return (worst, at);
  }

  static List<double> _reparameterize(List<Vec2> pts, int first, int last, List<double> u, List<Vec2> bez) {
    final d1 = [for (var i = 0; i < 3; i++) (bez[i + 1] - bez[i]) * 3];
    final d2 = [for (var i = 0; i < 2; i++) (d1[i + 1] - d1[i]) * 2];
    Vec2 q1(double t) {
      final mt = 1 - t;
      return d1[0] * (mt * mt) + d1[1] * (2 * mt * t) + d1[2] * (t * t);
    }

    Vec2 q2(double t) => d2[0] * (1 - t) + d2[1] * t;
    return [
      for (var i = 0; i <= last - first; i++)
        () {
          final t = u[i];
          final diff = _bezier(bez, t) - pts[first + i];
          final a = q1(t), b = q2(t);
          final den = _dot(a, a) + _dot(diff, b);
          return den.abs() < 1e-12 ? t : (t - _dot(diff, a) / den).clamp(0.0, 1.0);
        }(),
    ];
  }
}

/// One fitted piece: a line (two points) or a cubic (four), covering the
/// resampled stroke points `first..last`.
class _Piece {
  final List<Vec2> controls;
  final int first, last;
  const _Piece(this.controls, this.first, this.last);
}
