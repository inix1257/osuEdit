import 'dart:math' as math;

import '../geometry/slider_path.dart';
import '../model/beatmap.dart';
import '../model/hit_object.dart';
import '../model/timing_point.dart';

/// One beat-snap line on the timeline.
class BeatTick {
  final double time;

  /// Position inside the beat: 0 .. divisor-1 (0 = on the beat).
  final int indexInBeat;

  /// Beat number relative to the governing red point (may be negative
  /// before the first red point).
  final int beatIndex;

  /// Reduced denominator of `indexInBeat / divisor` (1 = whole beat,
  /// 2 = half, 4 = quarter, 3 = third...). The UI colours ticks by this.
  final int denominator;

  final bool isMeasureStart;

  const BeatTick({
    required this.time,
    required this.indexInBeat,
    required this.beatIndex,
    required this.denominator,
    required this.isMeasureStart,
  });
}

/// Timing queries over a sorted list of timing points.
///
/// Cheap to construct; rebuild it whenever `Beatmap.revision` changes
/// (see `EditorController.timing`).
class TimingInfo {
  /// All points, sorted by time (file order kept for ties).
  final List<TimingPoint> points;

  /// [points] in lookup order: at each time, red points from last to first
  /// in the file, then green points in file order. The last one at or before
  /// a time is what osu! applies there (lazer `flushPendingPoints`): BPM and
  /// meter from the first red line at that time, SV / kiai / samples from
  /// the last green line, else the first red line.
  final List<TimingPoint> _lookup;

  /// Red points in effect, sorted: one per time (the first in the file).
  final List<TimingPoint> redPoints;

  /// Times where kiai turns on (the effective point goes from not kiai to
  /// kiai), ascending.
  final List<double> kiaiStarts;

  TimingInfo(List<TimingPoint> sortedPoints) : this._(sortedPoints, _inLookupOrder(sortedPoints));

  TimingInfo._(List<TimingPoint> sorted, List<TimingPoint> lookup)
      : points = List.unmodifiable(sorted),
        _lookup = lookup,
        redPoints = List.unmodifiable(_effectiveReds(lookup)),
        kiaiStarts = List.unmodifiable(_kiaiStarts(lookup));

  static List<TimingPoint> _inLookupOrder(List<TimingPoint> sorted) {
    final out = <TimingPoint>[];
    for (var i = 0; i < sorted.length;) {
      var j = i + 1;
      while (j < sorted.length && sorted[j].time == sorted[i].time) {
        j++;
      }
      final group = sorted.sublist(i, j);
      out
        ..addAll(group.where((p) => p.uninherited).toList().reversed)
        ..addAll(group.where((p) => !p.uninherited));
      i = j;
    }
    return List.unmodifiable(out);
  }

  /// Valid red points of [lookup], the last of each time (= first in file).
  static List<TimingPoint> _effectiveReds(List<TimingPoint> lookup) {
    final out = <TimingPoint>[];
    for (final p in lookup) {
      if (!p.uninherited || !(p.beatLength > 0)) continue;
      if (out.isNotEmpty && out.last.time == p.time) out.removeLast();
      out.add(p);
    }
    return out;
  }

  static List<double> _kiaiStarts(List<TimingPoint> sorted) {
    final out = <double>[];
    var on = false;
    for (var i = 0; i < sorted.length; i++) {
      // Points at the same time: the last one decides (effectivePointAt).
      if (i + 1 < sorted.length && sorted[i + 1].time == sorted[i].time) continue;
      final k = sorted[i].kiai;
      if (k && !on) out.add(sorted[i].time);
      on = k;
    }
    return out;
  }

  /// The latest kiai start at or before [time], or null.
  double? lastKiaiStartAt(double time) {
    var lo = 0, hi = kiaiStarts.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (kiaiStarts[mid] <= time) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo == 0 ? null : kiaiStarts[lo - 1];
  }

  factory TimingInfo.of(Beatmap b) => TimingInfo(b.timingPoints);

  static double _t(TimingPoint p) => p.time;

  /// The red point governing [time]. Before the first red point, the first
  /// one applies (osu! extends it backwards). Null if the map has none.
  TimingPoint? redPointAt(double time) {
    if (redPoints.isEmpty) return null;
    final i = Beatmap.upperBound(redPoints, time, _t) - 1;
    return redPoints[i < 0 ? 0 : i];
  }

  /// The point whose SV / kiai / samples apply at [time]: the latest at or
  /// before it, with osu!'s precedence at equal times (see [_lookup]: a
  /// green line beats a red one whatever their order, the first red line
  /// beats later ones). Before the first point, the one in effect there.
  TimingPoint? effectivePointAt(double time) {
    if (_lookup.isEmpty) return null;
    return _lookup[Beatmap.upperBound(_lookup, math.max(time, _lookup.first.time), _t) - 1];
  }

  double beatLengthAt(double time) => redPointAt(time)?.beatLength ?? 500;

  double sliderVelocityAt(double time) =>
      effectivePointAt(time)?.sliderVelocity ?? 1;

  bool kiaiAt(double time) => effectivePointAt(time)?.kiai ?? false;

  /// Slider ball speed in osu!pixels per ms at [time].
  double sliderVelocityPxPerMs(double time, double sliderMultiplier) =>
      sliderMultiplier * 100 * sliderVelocityAt(time) / beatLengthAt(time);

  /// The distance osu! times [s] by: its path's ([SliderPath.distance]) —
  /// the `length` field, except the computed path when that is missing / 0,
  /// and no extension past a path ending in a repeated point.
  static double sliderDistance(SliderObject s) => SliderPath.cached(s).distance;

  /// Duration of one span (head→tail) of [s].
  double sliderSpanDuration(SliderObject s, double sliderMultiplier) {
    final v = sliderVelocityPxPerMs(s.time, sliderMultiplier);
    return v <= 0 ? 0 : sliderDistance(s) / v;
  }

  double sliderEndTime(SliderObject s, double sliderMultiplier) =>
      s.time + sliderSpanDuration(s, sliderMultiplier) * s.slides;

  /// Path distances (osu!pixels from the head) of the ticks inside one span
  /// of [s], ascending — the same set for every span (reverse spans pass
  /// them tail-first). lazer rules: one tick every `100 × SM × SV /
  /// tickRate` px (SV ignored before format v8), none closer than 10 ms of
  /// travel to the span end.
  List<double> sliderTickDistances(SliderObject s, double sliderMultiplier, double tickRate,
      {int formatVersion = 14}) {
    final length = sliderDistance(s);
    if (tickRate <= 0 || length <= 0) return const [];
    final sv = sliderVelocityAt(s.time);
    final scoring = 100 * sliderMultiplier * sv;
    final step = scoring / tickRate / (formatVersion < 8 ? sv : 1);
    if (!(step > 0)) return const [];
    final minFromEnd = scoring / beatLengthAt(s.time) * 10;
    final out = <double>[];
    for (var d = step; d < length - minFromEnd && out.length < 1000; d += step) {
      out.add(d);
    }
    return out;
  }

  /// Slider length (osu!pixels) covered in one 1/[divisor] beat at [time].
  double sliderLengthStep(double time, double sliderMultiplier, int divisor) =>
      sliderMultiplier * 100 * sliderVelocityAt(time) / (divisor <= 0 ? 1 : divisor);

  /// [length] rounded *down* to a whole number of 1/[divisor] beats (at
  /// least one), so the slider ends on the snap grid.
  double snapSliderLength(double length, double time, double sliderMultiplier, int divisor) {
    final step = sliderLengthStep(time, sliderMultiplier, divisor);
    if (step <= 0) return length;
    final n = (length / step + 1e-6).floor();
    return (n < 1 ? 1 : n) * step;
  }

  /// End time of any hit object.
  double endTimeOf(HitObject h, double sliderMultiplier) => switch (h) {
        SliderObject() => sliderEndTime(h, sliderMultiplier),
        _ => h.endTimeIfKnown,
      };

  // ---------------------------------------------------------------------------
  // Snapping

  /// The whole millisecond osu! stores for an object at [time] (`.osu`
  /// object times are integers): the nearest one still under the same
  /// control point as [time], so rounding never moves an object across a
  /// red or green line (files can have fractional point times). Placing and
  /// moving objects at stored times keeps the session as it will be saved:
  /// the SV, samples and kiai an object gets don't change on reload.
  double storedTime(double time) {
    final r = time.roundToDouble();
    final p = effectivePointAt(time);
    if (p == null || identical(effectivePointAt(r), p)) return r;
    for (final c in [time.floorToDouble(), time.ceilToDouble()]) {
      if (identical(effectivePointAt(c), p)) return c;
    }
    return r; // points less than 1 ms apart: can't keep it
  }

  /// Snaps [time] to the nearest 1/[divisor] beat of the governing red
  /// point, as a stored (whole ms, [storedTime]) time. Never snaps across
  /// the next red point.
  double snap(double time, int divisor) {
    final tp = redPointAt(time);
    if (tp == null || divisor <= 0) return storedTime(time);
    final step = tp.beatLength / divisor;
    final n = ((time - tp.time) / step).round();
    var result = tp.time + n * step;
    final next = _nextRedAfter(tp);
    if (next != null && result >= next.time) result = next.time;
    return storedTime(result);
  }

  /// The snap tick strictly after (`forward`) / before [time], as a
  /// stored time ([storedTime]).
  double stepSnap(double time, int divisor, {required bool forward}) {
    // ms; avoids getting stuck on float noise and on a tick stored up to
    // half a ms off.
    const eps = 0.5;
    final probe = forward ? time + eps : time - eps;
    final tp = redPointAt(probe);
    if (tp == null || divisor <= 0) return time;
    final step = tp.beatLength / divisor;
    final k = (probe - tp.time) / step;
    final n = forward ? k.ceil() : k.floor();
    var result = tp.time + n * step;
    final next = _nextRedAfter(tp);
    if (forward && next != null && result > next.time) result = next.time;
    return storedTime(result);
  }

  TimingPoint? _nextRedAfter(TimingPoint tp) {
    final i = redPoints.indexOf(tp);
    return i >= 0 && i + 1 < redPoints.length ? redPoints[i + 1] : null;
  }

  /// All snap ticks in [from, to). Capped at [maxTicks] to protect the UI
  /// from pathological zoom levels.
  List<BeatTick> ticks(double from, double to, int divisor,
      {int maxTicks = 20000}) {
    final out = <BeatTick>[];
    if (redPoints.isEmpty || divisor <= 0 || to <= from) return out;

    for (var i = 0; i < redPoints.length; i++) {
      final tp = redPoints[i];
      final segStart = i == 0 ? double.negativeInfinity : tp.time;
      final segEnd =
          i + 1 < redPoints.length ? redPoints[i + 1].time : double.infinity;
      final lo = math.max(from, segStart);
      final hi = math.min(to, segEnd);
      if (lo >= hi) continue;

      final step = tp.beatLength / divisor;
      var k = ((lo - tp.time) / step - 1e-9).ceil();
      final meter = tp.meter <= 0 ? 4 : tp.meter;
      for (;; k++) {
        final t = tp.time + k * step;
        if (t >= hi) break;
        if (out.length >= maxTicks) return out;
        final indexInBeat = k % divisor; // Dart % is non-negative
        final beatIndex = (k - indexInBeat) ~/ divisor;
        out.add(BeatTick(
          time: t,
          indexInBeat: indexInBeat,
          beatIndex: beatIndex,
          denominator: divisor ~/ _gcd(indexInBeat, divisor),
          isMeasureStart: indexInBeat == 0 && beatIndex % meter == 0,
        ));
      }
    }
    return out;
  }

  static int _gcd(int a, int b) {
    while (b != 0) {
      final t = a % b;
      a = b;
      b = t;
    }
    return a == 0 ? 1 : a.abs();
  }
}
