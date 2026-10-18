import 'dart:math' as math;

import '../math/vec2.dart';
import '../model/hit_object.dart';
import 'lazer_path.dart';
import 'path_approximator.dart';

/// The computed polyline of a slider, trimmed/extended to its expected
/// length, with distance-based lookups.
///
/// Building one is the expensive part of slider rendering, so the UI caches
/// instances per `SliderObject` (they're immutable).
class SliderPath {
  /// Polyline vertices from head to tail.
  final List<Vec2> vertices;

  /// `cumulative[i]` = path distance from head to `vertices[i]`.
  final List<double> cumulative;

  /// Final length: the slider's expected length when it is > 0, except a
  /// path ending in a repeated point is not extended (then the computed
  /// length). osu! times sliders by this, not by the `length` field.
  final double distance;

  SliderPath._(this.vertices, this.cumulative, this.distance);

  static final Expando<SliderPath> _cache = Expando();

  /// [SliderPath.of], built once per slider (they're immutable).
  static SliderPath cached(SliderObject s) => _cache[s] ??= SliderPath.of(s);

  factory SliderPath.of(SliderObject s) {
    final types = s.pointTypes;
    if (types != null) return SliderPath.fromTypedPoints(s.allPoints, types, s.length);
    return SliderPath.fromControlPoints(s.curveType, s.allPoints, s.length);
  }

  /// A path in osu!lazer's model (see `SliderObject.pointTypes`).
  factory SliderPath.fromTypedPoints(List<Vec2> points, List<PathType?> types, double expectedLength) =>
      _measured(LazerPath.approximate(points, types), expectedLength);

  factory SliderPath.fromControlPoints(
      CurveType type, List<Vec2> points, double expectedLength) {
    final raw = _approximate(type, points);
    return _measured(raw, expectedLength);
  }

  static List<Vec2> _approximate(CurveType type, List<Vec2> points) {
    if (points.length < 2) return List.of(points);
    switch (type) {
      case CurveType.linear:
        return PathApproximator.linear(points);
      case CurveType.catmull:
        return PathApproximator.catmull(points);
      case CurveType.perfectCircle:
        if (points.length == 3) {
          final arc = PathApproximator.circularArc(points);
          if (arc != null) return arc;
        }
        return _bezierSegments(points);
      case CurveType.bezier:
        return _bezierSegments(points);
    }
  }

  /// Bezier paths are split into independent segments at "red anchors"
  /// (the same point repeated twice in a row).
  static List<Vec2> _bezierSegments(List<Vec2> points) {
    final out = <Vec2>[];
    var start = 0;
    for (var i = 1; i <= points.length; i++) {
      final atEnd = i == points.length;
      if (atEnd || (points[i] == points[i - 1] && i - 1 > start)) {
        final seg = points.sublist(start, i);
        final approx = PathApproximator.bezier(seg);
        if (out.isNotEmpty && approx.isNotEmpty && out.last == approx.first) {
          out.addAll(approx.skip(1));
        } else {
          out.addAll(approx);
        }
        start = i;
      }
    }
    return out;
  }

  static SliderPath _measured(List<Vec2> raw, double expectedLength) {
    // osu-stable doesn't extend a path whose last two points are equal
    // (lazer `SliderPath.calculateLength`), e.g. `L|200:100|200:100`.
    final noExtension = raw.length >= 2 && raw.last == raw[raw.length - 2];
    // Drop consecutive duplicates (zero-length pieces break interpolation).
    final verts = <Vec2>[];
    for (final p in raw) {
      if (verts.isEmpty || verts.last != p) verts.add(p);
    }
    if (verts.isEmpty) return SliderPath._([Vec2.zero], [0], 0);
    if (verts.length == 1) {
      return SliderPath._(verts, [0], 0);
    }

    final cum = <double>[0];
    for (var i = 1; i < verts.length; i++) {
      cum.add(cum.last + verts[i].distanceTo(verts[i - 1]));
    }
    final computed = cum.last;
    if (expectedLength <= 0 ||
        (expectedLength - computed).abs() < 1e-6 ||
        (noExtension && expectedLength > computed)) {
      return SliderPath._(verts, cum, computed);
    }

    if (expectedLength < computed) {
      // Trim: drop vertices beyond the expected length, interpolate the end.
      var i = 1;
      while (i < cum.length && cum[i] < expectedLength) {
        i++;
      }
      final a = verts[i - 1], b = verts[i];
      final t = (expectedLength - cum[i - 1]) / (cum[i] - cum[i - 1]);
      final v = verts.sublist(0, i)..add(Vec2.lerp(a, b, t));
      final c = cum.sublist(0, i)..add(expectedLength);
      return SliderPath._(v, c, expectedLength);
    }

    // Extend the last segment in a straight line (osu! behaviour).
    final dir = (verts.last - verts[verts.length - 2]).normalized();
    final extra = expectedLength - computed;
    return SliderPath._(
      [...verts.sublist(0, verts.length - 1), verts.last + dir * extra],
      [...cum.sublist(0, cum.length - 1), expectedLength],
      expectedLength,
    );
  }

  Vec2 get head => vertices.first;
  Vec2 get tail => vertices.last;

  /// Position at path distance [d] (clamped to [0, distance]).
  Vec2 positionAtDistance(double d) {
    if (vertices.length == 1 || d <= 0) return vertices.first;
    if (d >= distance) return vertices.last;
    var lo = 0, hi = cumulative.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (cumulative[mid] < d) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final i = lo == 0 ? 1 : lo;
    final segLen = cumulative[i] - cumulative[i - 1];
    final t = segLen == 0 ? 0.0 : (d - cumulative[i - 1]) / segLen;
    return Vec2.lerp(vertices[i - 1], vertices[i], t);
  }

  /// Position at [progress] ∈ [0,1] along a single span.
  Vec2 positionAt(double progress) => positionAtDistance(progress * distance);

  /// Ball position at [time] for a slider starting at [startTime] whose spans
  /// each take [spanDuration] ms (handles repeats / reversed spans).
  Vec2 ballPositionAt(
      double time, double startTime, double spanDuration, int slides) {
    if (spanDuration <= 0) return head;
    final elapsed =
        ((time - startTime) / spanDuration).clamp(0.0, slides.toDouble());
    final span = math.min(elapsed.floor(), slides - 1);
    var p = elapsed - span;
    if (span.isOdd) p = 1 - p;
    return positionAt(p);
  }
}
