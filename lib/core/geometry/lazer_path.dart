import 'dart:math' as math;

import '../format/number_format.dart';
import '../math/vec2.dart';
import '../model/hit_object.dart';
import 'path_approximator.dart';

/// osu!lazer's slider path model: points (head first) where a point with a
/// [PathType] starts a segment of that type running to the next typed point
/// (`SliderObject.pointTypes`). Reading, writing, shape and editing rules
/// follow lazer (`ConvertHitObjectParser`, `LegacyBeatmapEncoder`,
/// `SliderPath`, `BezierConverter`, `PathControlPointVisualiser`; MIT),
/// rewritten here.
abstract final class LazerPath {
  /// lazer's first own `.osu` format version (`osu file format v128`).
  static const firstLazerVersion = 128;

  /// Whether a curve field (`B|1:2|3:4`) uses syntax only osu!lazer
  /// understands: a type letter after the first token (several curve types
  /// in one path) or a B-spline degree (`B4`). osu!stable reads such paths
  /// with a single curve type, so they look different there.
  static bool isLazerCurve(String curve) {
    final tokens = curve.split('|');
    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i].trim();
      if (t.isEmpty || !_isLetter(t)) continue;
      if (i > 0) return true;
      if (t.length > 1 && int.tryParse(t.substring(1)) != null) return true;
    }
    return false;
  }

  static bool _isLetter(String t) {
    final c = t.codeUnitAt(0);
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
  }

  /// lazer's reading of a curve field for a slider at [head]: the points
  /// (head first, absolute) and their types. Doubled points split a segment
  /// (the second copy is dropped and the first gets the type), like stable
  /// red anchors. [formatVersion] selects lazer's rules for older files
  /// (perfect curves that aren't three points become bezier, collinear ones
  /// linear; doubled catmull points don't split).
  static (List<Vec2>, List<PathType?>) decode(Vec2 head, String curve, {int formatVersion = 14}) {
    final points = <Vec2>[];
    final segments = <(PathType, int)>[];
    for (final raw in curve.split('|')) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      if (_isLetter(t)) {
        segments.add((PathType.parse(t), points.length));
        if (points.isEmpty) points.add(head);
        continue;
      }
      final colon = t.indexOf(':');
      if (colon < 0) continue;
      final x = parseDoubleLenient(t.substring(0, colon));
      final y = parseDoubleLenient(t.substring(colon + 1));
      if (x != null && y != null) points.add(Vec2(x, y));
    }
    if (points.isEmpty) points.add(head);
    if (segments.isEmpty) segments.add((PathType.bezier, 0));

    final outPoints = <Vec2>[];
    final outTypes = <PathType?>[];
    for (var k = 0; k < segments.length; k++) {
      final (type, start) = segments[k];
      final end = k + 1 < segments.length ? segments[k + 1].$2 : points.length;
      if (end <= start) continue; // a type letter with no point after it
      final endPoint = k + 1 < segments.length && end < points.length ? points[end] : null;
      _convertSegment(type, points.sublist(start, end), endPoint, formatVersion, outPoints, outTypes);
    }
    if (outTypes.isNotEmpty) outTypes[0] ??= PathType.bezier;
    return (outPoints, outTypes);
  }

  /// lazer `convertPoints`: one explicit segment, split at doubled points.
  static void _convertSegment(PathType type, List<Vec2> pts, Vec2? endPoint, int version,
      List<Vec2> outPoints, List<PathType?> outTypes) {
    if (type == PathType.perfectCurve) {
      final count = pts.length + (endPoint == null ? 0 : 1);
      if (version < firstLazerVersion) {
        if (count != 3) {
          type = PathType.bezier;
        } else if (_collinear(pts[0], pts[1], endPoint ?? pts[2])) {
          type = PathType.linear;
        }
      } else if (count > 3) {
        type = PathType.bezier;
      }
    }
    final n = pts.length;
    final types = List<PathType?>.filled(n, null)..[0] = type;
    var start = 0, end = 0;
    void emit(int from, int to) {
      for (var i = from; i < to; i++) {
        outPoints.add(pts[i]);
        outTypes.add(types[i]);
      }
    }

    while (++end < n) {
      if (pts[end] != pts[end - 1]) continue;
      if (type == PathType.catmull && end > 1 && version < firstLazerVersion) continue;
      if (end == n - 1) continue;
      types[end - 1] = type;
      emit(start, end);
      start = end + 1;
    }
    if (start < end) emit(start, end);
  }

  static bool _collinear(Vec2 a, Vec2 b, Vec2 c) =>
      ((b.y - a.y) * (c.x - a.x) - (b.x - a.x) * (c.y - a.y)).abs() < 1e-3;

  /// lazer's model of a stable-format path (`curveType` + points with
  /// doubled red anchors), as lazer reads it.
  static (List<Vec2>, List<PathType?>) fromStable(CurveType type, List<Vec2> allPoints) {
    if (allPoints.isEmpty) return (const [], const []);
    final tokens = [type.letter, for (final p in allPoints.skip(1)) '${formatNumber(p.x)}:${formatNumber(p.y)}'];
    return decode(allPoints.first, tokens.join('|'));
  }

  /// The curve field for [points] / [types] in lazer's syntax: each typed
  /// point is preceded by its type token (the head's comes first). The
  /// last point's type is dropped (it starts nothing).
  static String encodeCurve(List<Vec2> points, List<PathType?> types) {
    final out = <String>[];
    for (var i = 0; i < points.length; i++) {
      final t = i == 0 ? (types[0] ?? PathType.bezier) : (i < points.length - 1 ? types[i] : null);
      if (t != null) out.add(t.code);
      if (i > 0) out.add('${points[i].x.round()}:${points[i].y.round()}');
    }
    return out.join('|');
  }

  /// The same path in stable's format (one curve type, doubled points for
  /// red anchors), or null if stable can't express it: (type, all points).
  static (CurveType, List<Vec2>)? toStableForm(List<Vec2> points, List<PathType?> types) {
    if (points.isEmpty) return null;
    final first = types[0] ?? PathType.bezier;
    if (first.isBSpline) return null;
    final inner = [for (var i = 1; i < points.length - 1; i++) if (types[i] != null) i];
    if (inner.isEmpty) return (first.kind, List.of(points));
    // Linear segments joined end to end are one linear path.
    if (first == PathType.linear && inner.every((i) => types[i] == PathType.linear)) {
      return (CurveType.linear, List.of(points));
    }
    if (first == PathType.bezier && inner.every((i) => types[i] == PathType.bezier)) {
      return (CurveType.bezier, [
        for (var i = 0; i < points.length; i++) ...[points[i], if (inner.contains(i)) points[i]],
      ]);
    }
    return null;
  }

  /// Segments of the path: (type, first index, last index); consecutive
  /// segments share their boundary point.
  static List<(PathType, int, int)> segments(List<PathType?> types) {
    final out = <(PathType, int, int)>[];
    final n = types.length;
    if (n == 0) return out;
    var start = 0;
    for (var i = 1; i < n; i++) {
      if (types[i] == null && i < n - 1) continue;
      out.add((types[start] ?? PathType.linear, start, i));
      start = i;
    }
    if (n == 1) out.add((types[0] ?? PathType.linear, 0, 0));
    return out;
  }

  /// Polyline of the whole path (lazer `SliderPath.calculatePath`).
  static List<Vec2> approximate(List<Vec2> points, List<PathType?> types) {
    final out = <Vec2>[];
    for (final (type, from, to) in segments(types)) {
      final seg = points.sublist(from, to + 1);
      final sub = seg.length == 1 ? seg : approximateSegment(type, seg);
      final skipFirst = out.isNotEmpty && sub.isNotEmpty && out.last == sub.first;
      out.addAll(skipFirst ? sub.skip(1) : sub);
    }
    return out;
  }

  /// Polyline of one segment (lazer `SliderPath.calculateSubPath`).
  static List<Vec2> approximateSegment(PathType type, List<Vec2> pts) {
    switch (type.kind) {
      case CurveType.linear:
        return PathApproximator.linear(pts);
      case CurveType.perfectCircle:
        if (pts.length == 3) {
          final arc = PathApproximator.circularArc(pts);
          if (arc != null && arc.length < 1000) return arc;
        }
        return PathApproximator.bezier(pts);
      case CurveType.catmull:
        return PathApproximator.catmull(pts);
      case CurveType.bezier:
        final d = type.degree;
        if (d == null) return PathApproximator.bezier(pts);
        final out = <Vec2>[];
        for (final piece in bSplineToBeziers(pts, d)) {
          final sub = PathApproximator.bezier(piece);
          out.addAll(out.isNotEmpty && sub.isNotEmpty && out.last == sub.first ? sub.skip(1) : sub);
        }
        return out;
    }
  }

  /// A B-spline of [degree] through control points [pts] as consecutive
  /// bezier pieces (knot insertion, Boehm's algorithm; osu!framework
  /// `bSplineToBezierInternal`). Each piece ends where the next starts.
  static List<List<Vec2>> bSplineToBeziers(List<Vec2> pts, int degree) {
    if (pts.length < 2) return [List.of(pts)];
    degree = math.min(degree, pts.length - 1);
    final count = pts.length - 1;
    final points = List.of(pts);
    if (degree == count) return [points];
    final out = <List<Vec2>>[];
    for (var i = 0; i < count - degree; i++) {
      final sub = List<Vec2>.filled(degree + 1, Vec2.zero);
      sub[0] = points[i];
      for (var j = 0; j < degree - 1; j++) {
        sub[j + 1] = points[i + 1];
        for (var k = 1; k < degree - j; k++) {
          final l = math.min(k, count - degree - i);
          points[i + k] = (points[i + k] * l.toDouble() + points[i + k + 1]) / (l + 1).toDouble();
        }
      }
      sub[degree] = points[i + 1];
      out.add(sub);
    }
    out.add(points.sublist(count - degree));
    return out;
  }

  /// lazer `EnsureValidPathTypes`: a perfect curve segment of more than
  /// three points, or whose circle would be huge (640×480 osu!px or more),
  /// becomes bezier. Returns new types.
  static List<PathType?> ensureValid(List<Vec2> points, List<PathType?> types) {
    final out = List.of(types);
    if (out.isNotEmpty) out[0] ??= PathType.bezier;
    for (final (type, from, to) in segments(out)) {
      if (type != PathType.perfectCurve) continue;
      final count = to - from + 1;
      if (count > 3) {
        out[from] = PathType.bezier;
      } else if (count == 3) {
        final arc = PathApproximator.circularArc(points.sublist(from, to + 1));
        if (arc != null) {
          var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
          for (final v in arc) {
            minX = math.min(minX, v.x);
            maxX = math.max(maxX, v.x);
            minY = math.min(minY, v.y);
            maxY = math.max(maxY, v.y);
          }
          if (maxX - minX >= 640 || maxY - minY >= 480) out[from] = PathType.bezier;
        }
      }
    }
    return out;
  }

  /// lazer's automatic type for a drawn segment of [count] points (start
  /// and end included): 2 → linear, 3 → perfect curve, more → bezier.
  static PathType autoSegmentType(int count) => count <= 2
      ? PathType.linear
      : count == 3
          ? PathType.perfectCurve
          : PathType.bezier;

  /// The path as stable bezier anchors (lazer `BezierConverter
  /// .ConvertToModernBezier` + the legacy exporter): every segment becomes
  /// bezier pieces (circles approximated, linear / catmull / B-spline
  /// exactly), points rounded to whole osu!pixels, pieces joined by doubled
  /// points. Returns all points (head first) of a bezier slider.
  static List<Vec2> toStableBezier(List<Vec2> points, List<PathType?> types) {
    final anchors = <(Vec2, bool)>[]; // (position, starts a bezier piece)
    for (final (type, from, to) in segments(types)) {
      final seg = points.sublist(from, to + 1);
      final List<List<Vec2>> pieces;
      switch (type.kind) {
        case CurveType.catmull:
          pieces = _catmullToBeziers(seg);
        case CurveType.linear:
          pieces = [for (var i = 0; i < seg.length - 1; i++) [seg[i], seg[i + 1]]];
        case CurveType.perfectCircle:
          pieces = [circleToBezier(seg)];
        case CurveType.bezier:
          pieces = type.degree == null ? [seg] : bSplineToBeziers(seg, type.degree!);
      }
      for (final piece in pieces) {
        for (var j = 0; j < piece.length - 1; j++) {
          anchors.add((piece[j], j == 0));
        }
      }
    }
    anchors.add((points.last, false));

    final out = <Vec2>[];
    for (var i = 0; i < anchors.length; i++) {
      final p = anchors[i].$1.roundToInt();
      out.add(p);
      if (anchors[i].$2 && i > 0) out.add(p);
    }
    return out;
  }

  /// Exact bezier form of a catmull segment (one cubic per span).
  static List<List<Vec2>> _catmullToBeziers(List<Vec2> pts) {
    final n = pts.length;
    return [
      for (var i = 0; i < n - 1; i++)
        () {
          final v1 = i > 0 ? pts[i - 1] : pts[i];
          final v2 = pts[i];
          final v3 = i < n - 1 ? pts[i + 1] : v2 * 2 - v1;
          final v4 = i < n - 2 ? pts[i + 2] : v3 * 2 - v2;
          return [v2, (v2 * 6 - v1 + v3) / 6, (v3 * 6 - v4 + v2) / 6, v3];
        }(),
    ];
  }

  // Unit-circle bezier fits for arcs up to these angles (lazer
  // `BezierConverter.circle_presets`).
  static const _circlePresets = <(double, List<Vec2>)>[
    (0.4993379862754501, [Vec2(1, 0), Vec2(1, 0.2549893626632736), Vec2(0.8778997558480327, 0.47884446188920726)]),
    (1.7579419829169447, [Vec2(1, 0), Vec2(1, 0.6263026), Vec2(0.42931178, 1.0990661), Vec2(-0.18605515, 0.9825393)]),
    (
      3.1385246920140215,
      [Vec2(1, 0), Vec2(1, 0.87084764), Vec2(0.002304826, 1.5033062), Vec2(-0.9973236, 0.8739115), Vec2(-0.9999953, 0.0030679568)]
    ),
    (5.69720464620727, [
      Vec2(1, 0), Vec2(1, 1.4137783), Vec2(-1.4305235, 2.0779421), Vec2(-2.3410065, -0.94017583), //
      Vec2(0.05132711, -1.7309346), Vec2(0.8331702, -0.5530167),
    ]),
    (2 * math.pi, [
      Vec2(1, 0), Vec2(1, 1.2447058), Vec2(-0.8526471, 2.118367), Vec2(-2.6211002, 7.854936e-06), //
      Vec2(-0.8526448, -2.118357), Vec2(1, -1.2447058), Vec2(1, 0),
    ]),
  ];

  /// Bezier anchors approximating the circular arc through three points
  /// (lazer `ConvertCircleToBezierAnchors`); other inputs are returned as
  /// they are (they are drawn as bezier anyway).
  static List<Vec2> circleToBezier(List<Vec2> pts) {
    final arc = ArcProperties.of(pts);
    if (arc == null) return List.of(pts);
    var preset = _circlePresets.last;
    for (final p in _circlePresets) {
      if (p.$1 >= arc.thetaRange) {
        preset = p;
        break;
      }
    }
    final ctrl = List.of(preset.$2);
    final n = ctrl.length - 1;
    var tf = arc.thetaRange / preset.$1;
    // Shrink the preset arc until it spans exactly thetaRange.
    for (var guard = 0; (tf - 1).abs() > 1e-7 && guard < 1000; guard++) {
      for (var j = 0; j < n; j++) {
        for (var i = n; i > j; i--) {
          ctrl[i] = ctrl[i] * tf + ctrl[i - 1] * (1 - tf);
        }
      }
      var length = math.atan2(ctrl.last.y, ctrl.last.x);
      if (length < 0) length += 2 * math.pi;
      tf = arc.thetaRange / length;
    }
    final c = math.cos(arc.thetaStart), s = math.sin(arc.thetaStart);
    return [
      for (final p in ctrl)
        Vec2(
          (c * p.x - s * arc.direction * p.y) * arc.radius + arc.centre.x,
          (s * p.x + c * arc.direction * p.y) * arc.radius + arc.centre.y,
        ),
    ];
  }
}

/// The circle through three points (osu!framework `CircularArcProperties`).
class ArcProperties {
  final Vec2 centre;
  final double radius;
  final double thetaStart;
  final double thetaRange;

  /// 1 counter-clockwise (in osu!px, y down: as the angle grows), -1 the other way.
  final double direction;

  const ArcProperties(this.centre, this.radius, this.thetaStart, this.thetaRange, this.direction);

  /// Null unless exactly three non-collinear points.
  static ArcProperties? of(List<Vec2> pts) {
    if (pts.length != 3) return null;
    final a = pts[0], b = pts[1], c = pts[2];
    if (((b.y - a.y) * (c.x - a.x) - (b.x - a.x) * (c.y - a.y)).abs() < 1e-3) return null;
    final d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y));
    final aSq = a.lengthSquared, bSq = b.lengthSquared, cSq = c.lengthSquared;
    final centre = Vec2(
      (aSq * (b.y - c.y) + bSq * (c.y - a.y) + cSq * (a.y - b.y)) / d,
      (aSq * (c.x - b.x) + bSq * (a.x - c.x) + cSq * (b.x - a.x)) / d,
    );
    final dA = a - centre, dC = c - centre;
    final thetaStart = math.atan2(dA.y, dA.x);
    var thetaEnd = math.atan2(dC.y, dC.x);
    while (thetaEnd < thetaStart) {
      thetaEnd += 2 * math.pi;
    }
    var direction = 1.0;
    var range = thetaEnd - thetaStart;
    final ac = c - a;
    if (Vec2(ac.y, -ac.x).dot(b - a) < 0) {
      direction = -1;
      range = 2 * math.pi - range;
    }
    return ArcProperties(centre, dA.length, thetaStart, range, direction);
  }
}
