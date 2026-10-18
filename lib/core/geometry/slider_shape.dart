import '../math/vec2.dart';
import '../model/hit_object.dart';
import 'lazer_path.dart';
import 'slider_path.dart';

/// One editable control point of a slider path. A [red] point is a segment
/// boundary ("red anchor"); in the file it is written twice in a row.
/// In osu!lazer's model ([SliderShape.typedOf]) a point instead has a
/// [type] when it starts a segment of that curve type.
class PathPoint {
  final Vec2 position;
  final bool red;
  final PathType? type;
  const PathPoint(this.position, {this.red = false, this.type});

  PathPoint withPosition(Vec2 p) => PathPoint(p, red: red, type: type);
  PathPoint withType(PathType? t) => PathPoint(position, red: red, type: t);
}

/// Conversions between a slider's stored points and an editable list of
/// [PathPoint]s, plus the shape rules used when creating / editing sliders.
abstract final class SliderShape {
  /// Head + control points → editable points (doubled points collapse into
  /// one red point). The first point is always the head.
  static List<PathPoint> decode(List<Vec2> allPoints) {
    final out = <PathPoint>[];
    for (var i = 0; i < allPoints.length; i++) {
      final p = allPoints[i];
      if (out.isNotEmpty && out.last.position == p) {
        // Head and tail can't be segment boundaries.
        if (out.length > 1) out[out.length - 1] = PathPoint(p, red: true);
        continue;
      }
      out.add(PathPoint(p));
    }
    if (out.isNotEmpty && out.last.red) out[out.length - 1] = PathPoint(out.last.position);
    return out;
  }

  /// [s]'s points in osu!lazer's model: one per point (no doubles), the
  /// first of each segment with its type. A stable-format slider is read
  /// the way lazer reads it (red anchors become bezier-typed points).
  static List<PathPoint> typedOf(SliderObject s) {
    final types = s.pointTypes;
    final (points, t) = types != null ? (s.allPoints, types) : LazerPath.fromStable(s.curveType, s.allPoints);
    return [for (var i = 0; i < points.length; i++) PathPoint(points[i], type: t[i])];
  }

  /// Inverse of [decode]: red interior points are written twice.
  static List<Vec2> encode(List<PathPoint> points) => [
        for (var i = 0; i < points.length; i++) ...[
          points[i].position,
          if (points[i].red && i > 0 && i < points.length - 1) points[i].position,
        ],
      ];

  /// osu!stable's choice for a freshly drawn path: 2 points → linear,
  /// 3 non-collinear points → perfect circle, otherwise bezier. Red anchors
  /// only exist on bezier paths.
  static CurveType autoType(List<PathPoint> points) {
    if (points.any((p) => p.red)) return CurveType.bezier;
    if (points.length <= 2) return CurveType.linear;
    if (points.length == 3 && !_collinear(points[0].position, points[1].position, points[2].position)) {
      return CurveType.perfectCircle;
    }
    return CurveType.bezier;
  }

  static bool _collinear(Vec2 a, Vec2 b, Vec2 c) =>
      ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)).abs() < 1e-3 * (1 + a.distanceTo(c));

  /// Length of the drawn path, before trimming to the slider's length.
  static double fullLength(CurveType type, List<Vec2> allPoints) =>
      SliderPath.fromControlPoints(type, allPoints, 0).distance;

  /// [list] resized to `slides + 1` edges: existing ones are kept, the tail
  /// keeps the old tail's value, new repeats get [fill]. Null stays null.
  static List<T>? resizeEdges<T>(List<T>? list, int slides, T fill) {
    if (list == null || list.isEmpty) return list;
    final edges = slides + 1;
    return [
      for (var i = 0; i < edges; i++)
        i == edges - 1
            ? list.last
            : i < list.length - 1
                ? list[i]
                : fill,
    ];
  }
}
