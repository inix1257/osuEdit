import '../model/hit_object.dart';
import '../timing/timing_info.dart';

enum PatternIssueKind { overlap, unsnapped }

/// Two objects that play at the same time (osu!standard): they start together,
/// or [b] starts while the slider / spinner [a] is running or just ending.
class OverlapIssue {
  /// When the clash begins (the later start time).
  final double time;
  final HitObject a;
  final HitObject b;
  final PatternIssueKind kind;

  const OverlapIssue(this.time, this.a, this.b, {this.kind = PatternIssueKind.overlap});
}

/// Finds abnormal overlaps in [objects] (sorted by time): objects starting at
/// the same time, and objects starting inside (or exactly at the end of) another slider or spinner.
/// Returned sorted by [OverlapIssue.time]. Only meaningful for osu!standard.
List<OverlapIssue> findOverlaps(
  List<HitObject> objects, {
  required double Function(HitObject h) endTime,
  double tolerance = 1.0,
}) {
  final out = <OverlapIssue>[];
  for (var i = 0; i < objects.length; i++) {
    final a = objects[i];
    final aEnd = endTime(a);
    for (var j = i + 1; j < objects.length; j++) {
      final b = objects[j];
      final sameStart = b.time - a.time < tolerance;
      // Starting exactly when a slider / spinner ends counts too.
      final inside = b.time < aEnd + tolerance;
      if (!sameStart && !inside) break;
      out.add(OverlapIssue(b.time, a, b));
    }
  }
  out.sort((x, y) => x.time.compareTo(y.time));
  return out;
}

/// Beat divisors accepted as "snapped" (osu!stable's snap choices).
const snapDivisors = [1, 2, 3, 4, 6, 8, 12, 16];

/// Objects whose start (or slider end) sits on none of the [snapDivisors]
/// beat grids, within [tolerance] ms (times are stored as whole ms). Spinners
/// are ignored. Reported at the object's start time, with `a == b`.
List<OverlapIssue> findUnsnapped(
  List<HitObject> objects,
  TimingInfo timing, {
  required double Function(HitObject h) endTime,
  double tolerance = 2.0,
  double sliderEndTolerance = 3.0,
}) {
  if (timing.redPoints.isEmpty) return const [];

  bool snapped(double t, double tol) {
    for (final d in snapDivisors) {
      if ((timing.snap(t, d) - t).abs() <= tol) return true;
    }
    return false;
  }

  final out = <OverlapIssue>[];
  for (final o in objects) {
    if (o is Spinner) continue;
    final bad = !snapped(o.time, tolerance) ||
        (o is SliderObject && !snapped(endTime(o), sliderEndTolerance));
    if (bad) out.add(OverlapIssue(o.time, o, o, kind: PatternIssueKind.unsnapped));
  }
  return out;
}
