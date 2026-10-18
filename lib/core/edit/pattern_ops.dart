import 'dart:math' as math;

import '../geometry/lazer_path.dart';
import '../geometry/path_approximator.dart';
import '../geometry/slider_path.dart';
import '../geometry/slider_shape.dart';
import '../math/vec2.dart';
import '../model/hit_object.dart';
import 'slider_format_ops.dart';

/// Pattern edits ported from osu!lazer's editor: "Convert to stream"
/// (`SliderSelectionBlueprint.convertToStream`), "Reverse" (Ctrl+G,
/// `OsuSelectionHandler.HandleReverse`) and "Merge selection"
/// (Ctrl+Shift+M). Pure functions; the editor wraps them in undoable
/// commands.
abstract final class PatternOps {
  static double _wholeMs(double t) => t.roundToDouble();

  /// Circles along [s] every [spacing] ms from its head to its end (lazer:
  /// while the time isn't more than 1 ms past the end). Circles that land on
  /// a slider edge (head, repeats, tail) take that edge's hitsound and sample
  /// sets; the others get no additions. The first keeps the new combo.
  /// Circle times go through [storedTime] (whole ms, `TimingInfo.storedTime`).
  static List<HitCircle> sliderToStream(
    SliderObject s, {
    required SliderPath path,
    required double spanDuration,
    required double spacing,
    double Function(double) storedTime = _wholeMs,
  }) {
    if (!(spacing > 0)) return const [];
    final end = s.time + spanDuration * s.slides;
    final base = HitSample(
      normalSet: s.sample.normalSet,
      additionSet: s.sample.additionSet,
      index: s.sample.index,
      volume: s.sample.volume,
    );
    final out = <HitCircle>[];
    for (var i = 0; i < 10000; i++) {
      final t = s.time + i * spacing;
      if (t > end + 1) break;
      var sound = 0;
      var sample = base;
      final edge = spanDuration > 0 ? ((t - s.time) / spanDuration).round() : 0;
      if (edge <= s.slides && (s.time + edge * spanDuration - t).abs() < 1) {
        final sounds = s.edgeSounds, sets = s.edgeSets;
        sound = sounds != null && edge < sounds.length ? sounds[edge] : s.hitSound;
        final set = sets != null && edge < sets.length ? sets[edge] : null;
        if (set != null) {
          sample = HitSample(
            normalSet: set.normalSet == 0 ? base.normalSet : set.normalSet,
            additionSet: set.additionSet == 0 ? base.additionSet : set.additionSet,
            index: base.index,
            volume: base.volume,
          );
        }
      }
      out.add(HitCircle(
        position: path.ballPositionAt(t, s.time, spanDuration, s.slides).roundToInt(),
        time: storedTime(t),
        newCombo: i == 0 && s.newCombo,
        comboSkip: i == 0 ? s.comboSkip : 0,
        hitSound: sound,
        sample: sample,
      ));
    }
    return out;
  }

  static double _sameLength(double length) => length;

  /// lazer's "Merge selection" (Ctrl+Shift+M,
  /// `OsuSelectionHandler.mergeSelection`): the circles and sliders of
  /// [objs], in time order, become one slider from the first one's head. A
  /// circle adds a straight segment to it; a slider adds its whole path,
  /// moved so it starts where the merged path ends (unless a circle came
  /// just before: then it stays in place, joined by a straight segment). A
  /// first slider keeps its other fields (repeats, edge sounds); otherwise
  /// the new slider takes the first circle's combo and samples. Its length
  /// is lazer's (the path through the circles; with sliders, up to the
  /// last slider's end), passed through [lengthOf] (the editor snaps it to
  /// the beat). The result is in lazer's path model with [lazerFormat],
  /// else converted to stable's ([SliderFormatOps.toStable]).
  ///
  /// Returns the merged objects (to remove) and the slider (to add), or null
  /// when lazer refuses: fewer than two circles / sliders, or only circles
  /// all on (nearly) the same spot. Spinners are ignored.
  static (List<HitObject>, SliderObject)? merged(
    List<HitObject> objs, {
    required bool lazerFormat,
    double Function(double length) lengthOf = _sameLength,
  }) {
    final items = _mergeable(objs);
    if (!_canMerge(items)) return null;

    final first = items.first;
    final pts = <Vec2>[];
    final types = <PathType?>[];
    double? expected;
    if (first is SliderObject) {
      for (final p in SliderShape.typedOf(first)) {
        pts.add(p.position);
        types.add(p.type);
      }
      expected = first.length > 0 ? first.length : null;
    } else {
      pts.add(first.position);
      types.add(PathType.linear);
    }

    var lastCircle = first is HitCircle;
    for (final h in items.skip(1)) {
      if (h is SliderObject) {
        final shift = lastCircle ? Vec2.zero : pts.last - h.position;
        final distanceToLast = pts.last.distanceTo(h.position + shift);
        final calculated = SliderPath.fromTypedPoints(pts, LazerPath.ensureValid(pts, types), 0).distance;
        expected = calculated + distanceToLast + SliderPath.of(h).distance;
        if (distanceToLast.abs() < 1e-3) {
          pts.removeLast();
          types.removeLast();
        }
        for (final p in SliderShape.typedOf(h)) {
          pts.add(p.position + shift);
          types.add(p.type);
        }
        lastCircle = false;
      } else {
        if (!lastCircle) types[types.length - 1] = PathType.linear;
        pts.add(h.position);
        types.add(null);
        expected = null;
        lastCircle = true;
      }
    }

    final valid = LazerPath.ensureValid(pts, types);
    if (valid.length > 1) valid[valid.length - 1] = null; // starts nothing
    final length = lengthOf(expected ?? SliderPath.fromTypedPoints(pts, valid, 0).distance);
    var slider = first is SliderObject
        ? first.copyWith(controlPoints: pts.sublist(1), curveType: valid.first!.kind, pointTypes: valid, length: length)
        : SliderObject(
            position: first.position,
            time: first.time,
            curveType: valid.first!.kind,
            controlPoints: pts.sublist(1),
            pointTypes: valid,
            length: length,
            newCombo: first.newCombo,
            comboSkip: first.comboSkip,
            hitSound: first.hitSound,
            sample: first.sample,
          );
    if (!lazerFormat) slider = SliderFormatOps.toStable(slider);
    return (items, slider);
  }

  /// Whether [merged] would merge [objs] (lazer's `canMerge`).
  static bool canMerge(Iterable<HitObject> objs) => _canMerge(_mergeable(objs));

  static List<HitObject> _mergeable(Iterable<HitObject> objs) {
    final items = [for (final h in objs) if (h is HitCircle || h is SliderObject) h];
    _stableSortByTime(items);
    return items;
  }

  static bool _canMerge(List<HitObject> items) {
    if (items.length < 2) return false;
    if (items.any((h) => h is SliderObject)) return true;
    for (var i = 1; i < items.length; i++) {
      final d = items[i].position - items[i - 1].position;
      if (d.x * d.x + d.y * d.y > 1 + 1e-3) return true;
    }
    return false;
  }

  static void _stableSortByTime(List<HitObject> list) {
    final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])]
      ..sort((a, b) {
        final c = a.$2.time.compareTo(b.$2.time);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    for (var i = 0; i < list.length; i++) {
      list[i] = indexed[i].$2;
    }
  }

  /// [objs] reversed in time (lazer's Reverse): with more than one object,
  /// each one's span is mirrored inside the selection's time range
  /// (`start' = selectionEnd − (end − selectionStart)`); sliders also run
  /// their path backwards. New combo flags stay in place in time order (the
  /// first object keeps starting the combo). Returns the replaced objects
  /// and their replacements, index for index; objects that don't change are
  /// left out (their source lines are kept). New start times go through
  /// [storedTime] (whole ms: mirrored slider ends are fractional).
  static (List<HitObject>, List<HitObject>) reversed(
    List<HitObject> objs, {
    required double Function(HitObject) endTime,
    required SliderPath Function(SliderObject) pathOf,
    double Function(double) storedTime = _wholeMs,
  }) {
    final sorted = [...objs]..sort((a, b) => a.time.compareTo(b.time));
    if (sorted.isEmpty) return (const [], const []);
    final start = sorted.first.time;
    final end = sorted.map(endTime).reduce(math.max);
    final mirror = sorted.length > 1;
    final combos = [for (final h in sorted) (h.newCombo, h.comboSkip)];

    final moved = <(HitObject, HitObject)>[];
    for (final h in sorted) {
      var next = mirror ? h.shiftedInTime(storedTime(end - (endTime(h) - start)) - h.time) : h;
      if (next is SliderObject) next = reversedPath(next, pathOf(h as SliderObject));
      moved.add((h, next));
    }
    // Stable sort: equal start times keep their order.
    final order = List.generate(moved.length, (i) => i)
      ..sort((a, b) {
        final c = moved[a].$2.time.compareTo(moved[b].$2.time);
        return c != 0 ? c : a.compareTo(b);
      });

    final before = <HitObject>[], after = <HitObject>[];
    for (var rank = 0; rank < order.length; rank++) {
      final (orig, next) = moved[order[rank]];
      final (nc, skip) = combos[rank];
      final unchanged = identical(orig, next) || (orig is! SliderObject && next.time == orig.time);
      if (unchanged && orig.newCombo == nc && orig.comboSkip == skip) continue;
      before.add(orig);
      after.add(next.copyWithBase(newCombo: nc, comboSkip: nc ? skip : 0));
    }
    return (before, after);
  }

  /// [s] with its path running from its tail to its head. [path] is [s]'s
  /// computed path (trimmed / extended to its length). The points are first
  /// cut so the path ends exactly at the tail, so the shape is kept:
  /// bezier segments past the end are dropped and the last one is
  /// subdivided; an extended end becomes a straight segment. Edge
  /// hitsounds are reversed too.
  static SliderObject reversedPath(SliderObject s, SliderPath path) {
    if (s.pointTypes != null) return _reversedTyped(s, path);
    final (type, pts) = _cutToLength(s.curveType, SliderShape.decode(s.allPoints), path);
    final all = SliderShape.encode(pts.reversed.toList());
    return s.copyWith(
      position: all.first,
      controlPoints: all.sublist(1),
      curveType: type,
      edgeSounds: s.edgeSounds?.reversed.toList(),
      edgeSets: s.edgeSets?.reversed.toList(),
    );
  }

  /// [reversedPath] for a path in osu!lazer's model: the segments past the
  /// end are dropped, the one the end falls in is cut like a stable path of
  /// its type, then the points are reversed and each segment's type moves
  /// to its new first point.
  static SliderObject _reversedTyped(SliderObject s, SliderPath path) {
    final (pts, types) = _cutTyped(s.allPoints, s.pointTypes!, path.distance, path.tail.roundToInt());
    final n = pts.length;
    final reversedTypes = List<PathType?>.filled(n, null);
    for (final (type, _, to) in LazerPath.segments(types)) {
      reversedTypes[n - 1 - to] = type;
    }
    final reversed = pts.reversed.toList();
    return s.copyWith(
      position: reversed.first,
      controlPoints: reversed.sublist(1),
      pointTypes: reversedTypes,
      curveType: reversedTypes.first!.kind,
      edgeSounds: s.edgeSounds?.reversed.toList(),
      edgeSets: s.edgeSets?.reversed.toList(),
    );
  }

  static (List<Vec2>, List<PathType?>) _cutTyped(List<Vec2> points, List<PathType?> types, double length, Vec2 tail) {
    final segs = LazerPath.segments(types);
    var travelled = 0.0;
    for (var k = 0; k < segs.length; k++) {
      final (type, from, to) = segs[k];
      final seg = points.sublist(from, to + 1);
      final segLength = seg.length < 2 ? 0.0 : _polylineLength(LazerPath.approximateSegment(type, seg));
      if (travelled + segLength < length - 0.5) {
        travelled += segLength;
        continue;
      }
      if (travelled + segLength <= length + 0.5) {
        // Ends on this segment's last point: drop the segments after it.
        return (points.sublist(0, to + 1), [...types.sublist(0, to), null]);
      }
      // The end is inside this segment: cut it like a stable path.
      final List<PathPoint> stablePoints;
      final CurveType stableType;
      if (type.isBSpline) {
        final pieces = LazerPath.bSplineToBeziers(seg, type.degree!);
        stablePoints = SliderShape.decode([
          // Pieces join with a doubled point (a red anchor).
          for (var i = 0; i < pieces.length; i++) ...[if (i > 0) pieces[i].first, ...pieces[i]],
        ]);
        stableType = CurveType.bezier;
      } else {
        stablePoints = [for (final p in seg) PathPoint(p)];
        stableType = type.kind;
      }
      final segPath = SliderPath.fromControlPoints(stableType, SliderShape.encode(stablePoints), length - travelled);
      final (cutType, cut) = _cutToLength(stableType, stablePoints, segPath);
      return (
        [...points.sublist(0, from), for (final p in cut) p.position],
        [
          ...types.sublist(0, from),
          for (var i = 0; i < cut.length; i++)
            i == 0 ? (cutType == type.kind && !type.isBSpline ? type : PathType(cutType)) : (cut[i].red ? PathType.bezier : null),
        ],
      );
    }
    if (length > travelled + 0.5 && points.length >= 2) {
      // Extended past the drawn path: a straight segment to the end.
      return ([...points, tail], [...types.sublist(0, types.length - 1), PathType.linear, null]);
    }
    return (points, types);
  }

  static double _polylineLength(List<Vec2> v) {
    var d = 0.0;
    for (var i = 1; i < v.length; i++) {
      d += v[i].distanceTo(v[i - 1]);
    }
    return d;
  }

  static (CurveType, List<PathPoint>) _cutToLength(CurveType type, List<PathPoint> pts, SliderPath path) {
    if (pts.length < 2) return (type, pts);
    final length = path.distance;
    final tail = path.tail.roundToInt();
    final all = SliderShape.encode(pts);
    final full = SliderShape.fullLength(type, all);
    if ((length - full).abs() < 0.5) return (type, pts);

    switch (type) {
      case CurveType.linear:
        // Keep the corners before the end, then end at the tail (an
        // extension continues the last segment, so this is exact too).
        final out = [pts.first];
        var d = 0.0;
        for (var i = 1; i < pts.length - 1; i++) {
          d += pts[i].position.distanceTo(pts[i - 1].position);
          if (d >= length) break;
          out.add(pts[i]);
        }
        return (type, out..add(PathPoint(tail)));
      case CurveType.perfectCircle when pts.length == 3 && PathApproximator.circularArc(all) != null:
        // Three points on the (cut) arc describe the same circle.
        return (type, [pts.first, PathPoint(path.positionAtDistance(length / 2).roundToInt()), PathPoint(tail)]);
      case CurveType.catmull:
        return (type, [...pts.sublist(0, pts.length - 1), PathPoint(tail)]);
      case CurveType.bezier:
      case CurveType.perfectCircle:
        return (CurveType.bezier, _cutBezier(pts, length, tail));
    }
  }

  /// Bezier [pts] (red points split segments) cut at path distance
  /// [length]; past the end, a straight segment to [tail] is added.
  static List<PathPoint> _cutBezier(List<PathPoint> pts, double length, Vec2 tail) {
    // Segments as index ranges [from, to] into pts (shared boundary points).
    final bounds = [0, for (var i = 1; i < pts.length - 1; i++) if (pts[i].red) i, pts.length - 1];
    var travelled = 0.0;
    for (var k = 0; k < bounds.length - 1; k++) {
      final seg = [for (var i = bounds[k]; i <= bounds[k + 1]; i++) pts[i].position];
      final segLength = SliderShape.fullLength(CurveType.bezier, seg);
      if (travelled + segLength < length - 0.5) {
        travelled += segLength;
        continue;
      }
      if (travelled + segLength <= length + 0.5) {
        // Ends on this segment's last point: drop the segments after it.
        return [...pts.sublist(0, bounds[k + 1]), PathPoint(pts[bounds[k + 1]].position)];
      }
      final kept = pts.sublist(0, bounds[k]);
      final left = _subdivide(seg, _paramAtDistance(seg, length - travelled));
      final out = [...kept, for (final p in left) PathPoint(p.roundToInt())];
      // The segment's first point keeps its red flag (it's a boundary).
      out[bounds[k]] = PathPoint(out[bounds[k]].position, red: bounds[k] != 0);
      out[out.length - 1] = PathPoint(tail);
      return _dedupe(out);
    }
    // Extended past the drawn path: the extension is straight.
    final out = [...pts];
    out[out.length - 1] = PathPoint(out.last.position, red: true);
    return _dedupe(out..add(PathPoint(tail)));
  }

  /// Drops points equal to the one before (a rounded subdivision can
  /// collapse), keeping red flags; head and tail are never red.
  static List<PathPoint> _dedupe(List<PathPoint> pts) {
    final out = <PathPoint>[];
    for (final p in pts) {
      if (out.isNotEmpty && out.last.position == p.position) {
        out[out.length - 1] = PathPoint(p.position, red: out.last.red || p.red);
      } else {
        out.add(p);
      }
    }
    if (out.length < 2 && pts.length >= 2) return [pts.first, pts.last];
    out[0] = PathPoint(out.first.position);
    out[out.length - 1] = PathPoint(out.last.position);
    return out;
  }

  /// Bezier parameter at arc length [d] of the curve [cps], by sampling.
  static double _paramAtDistance(List<Vec2> cps, double d) {
    const n = 512;
    var prev = cps.first;
    var acc = 0.0;
    for (var i = 1; i <= n; i++) {
      final t = i / n;
      final p = _bezierAt(cps, t);
      final step = p.distanceTo(prev);
      if (acc + step >= d) {
        final f = step == 0 ? 0.0 : (d - acc) / step;
        return (i - 1 + f) / n;
      }
      acc += step;
      prev = p;
    }
    return 1;
  }

  static Vec2 _bezierAt(List<Vec2> cps, double t) {
    final w = [...cps];
    for (var r = 1; r < w.length; r++) {
      for (var i = 0; i < w.length - r; i++) {
        w[i] = Vec2.lerp(w[i], w[i + 1], t);
      }
    }
    return w.first;
  }

  /// Control points of the part of the bezier [cps] over [0, t] (de
  /// Casteljau): the same curve, ending at B(t).
  static List<Vec2> _subdivide(List<Vec2> cps, double t) {
    final w = [...cps];
    final left = [w.first];
    for (var r = 1; r < cps.length; r++) {
      for (var i = 0; i < w.length - r; i++) {
        w[i] = Vec2.lerp(w[i], w[i + 1], t);
      }
      left.add(w.first);
    }
    return left;
  }
}
