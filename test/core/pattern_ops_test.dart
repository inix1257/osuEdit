import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

SliderObject _slider(CurveType type, List<Vec2> pts, double length, {int slides = 1, double time = 0}) =>
    SliderObject(
      position: pts.first,
      time: time,
      curveType: type,
      controlPoints: pts.sublist(1),
      slides: slides,
      length: length,
    );

/// [b] runs along [a] backwards: b(d) == a(length − d).
void _expectReversedShape(SliderObject a, SliderObject b, {double tolerance = 1.5}) {
  final pa = SliderPath.of(a), pb = SliderPath.of(b);
  expect(pb.distance, closeTo(pa.distance, 1e-6));
  for (var i = 0; i <= 20; i++) {
    final d = pa.distance * i / 20;
    final p = pb.positionAtDistance(d), q = pa.positionAtDistance(pa.distance - d);
    expect(p.distanceTo(q), lessThan(tolerance), reason: 'at $d: $p vs $q');
  }
}

void main() {
  group('slider to stream', () {
    test('circles every spacing along the path, back and forth over repeats', () {
      final s = SliderObject(
        position: const Vec2(0, 0),
        time: 1000,
        curveType: CurveType.linear,
        controlPoints: const [Vec2(100, 0)],
        slides: 2,
        length: 100,
        newCombo: true,
        comboSkip: 2,
        hitSound: 2,
        edgeSounds: const [8, 4, 2],
        edgeSets: const [EdgeSet(2, 0), EdgeSet(0, 0), EdgeSet(0, 3)],
        sample: const HitSample(normalSet: 1, additionSet: 1, volume: 70, filename: 'x.wav'),
      );
      final out = PatternOps.sliderToStream(s, path: SliderPath.of(s), spanDuration: 400, spacing: 100);
      expect(out.map((c) => c.time), [1000, 1100, 1200, 1300, 1400, 1500, 1600, 1700, 1800]);
      expect(out.map((c) => c.position.x), [0, 25, 50, 75, 100, 75, 50, 25, 0]);
      // Only the first circle starts the combo.
      expect(out.first.newCombo, isTrue);
      expect(out.first.comboSkip, 2);
      expect(out.skip(1).every((c) => !c.newCombo && c.comboSkip == 0), isTrue);
      // Edges take their sounds and sets; the rest have no additions.
      expect([out[0].hitSound, out[4].hitSound, out[8].hitSound], [8, 4, 2]);
      expect(out[0].sample.normalSet, 2);
      expect(out[0].sample.additionSet, 1);
      expect(out[8].sample.additionSet, 3);
      expect(out[1].hitSound, 0);
      expect(out[1].sample, const HitSample(normalSet: 1, additionSet: 1, volume: 70));
    });

    test('stops within 1 ms past the end; a slider without edge sounds uses its hitsound at edges', () {
      final s = _slider(CurveType.linear, const [Vec2(0, 0), Vec2(90, 0)], 90).copyWith(hitSound: 4);
      final out = PatternOps.sliderToStream(s, path: SliderPath.of(s), spanDuration: 300.5, spacing: 100);
      expect(out.map((c) => c.time), [0, 100, 200, 300]); // 300 ≤ 300.5 + 1
      // 300 is within 1 ms of the tail (300.5), so it is an edge.
      expect(out.map((c) => c.hitSound), [4, 0, 0, 4]);
    });
  });

  group('reversed path', () {
    test('linear: cut at the trimmed tail, then reversed', () {
      final s = _slider(CurveType.linear, const [Vec2(0, 0), Vec2(100, 0), Vec2(100, 100)], 150);
      final r = PatternOps.reversedPath(s, SliderPath.of(s));
      expect(r.allPoints, const [Vec2(100, 50), Vec2(100, 0), Vec2(0, 0)]);
      _expectReversedShape(s, r);
    });

    test('linear extended past its last point', () {
      final s = _slider(CurveType.linear, const [Vec2(0, 0), Vec2(100, 0)], 150);
      final r = PatternOps.reversedPath(s, SliderPath.of(s));
      expect(r.allPoints, const [Vec2(150, 0), Vec2(0, 0)]);
    });

    test('bezier trimmed mid-segment keeps its shape (subdivided)', () {
      final s = _slider(CurveType.bezier, const [Vec2(0, 0), Vec2(100, 200), Vec2(200, 0)], 150);
      final r = PatternOps.reversedPath(s, SliderPath.of(s));
      expect(r.curveType, CurveType.bezier);
      _expectReversedShape(s, r);
    });

    test('bezier with red anchors: later segments are dropped', () {
      final s = SliderObject(
        position: const Vec2(120, 200),
        time: 0,
        curveType: CurveType.bezier,
        controlPoints: const [Vec2(160, 140), Vec2(160, 140), Vec2(240, 140), Vec2(260, 80)],
        length: 150,
      );
      final full = SliderShape.fullLength(CurveType.bezier, s.allPoints);
      expect(full, greaterThan(150));
      final r = PatternOps.reversedPath(s, SliderPath.of(s));
      _expectReversedShape(s, r);
      // Longer than drawn (sample_v14's 210): extended straight.
      final long = s.copyWith(length: 210);
      _expectReversedShape(long, PatternOps.reversedPath(long, SliderPath.of(long)));
      // Cut short of the anchor: only the first segment is left.
      final short = s.copyWith(length: 50);
      final rs = PatternOps.reversedPath(short, SliderPath.of(short));
      expect(rs.allPoints.length, 2);
      _expectReversedShape(short, rs);
    });

    test('bezier extended past its end adds a straight segment', () {
      final s = _slider(CurveType.bezier, const [Vec2(0, 0), Vec2(50, 100), Vec2(100, 0)], 250);
      final r = PatternOps.reversedPath(s, SliderPath.of(s));
      _expectReversedShape(s, r);
    });

    test('perfect circle trimmed stays a circle through the cut arc', () {
      final s = _slider(CurveType.perfectCircle, const [Vec2(256, 192), Vec2(300, 120), Vec2(360, 192)], 140);
      final r = PatternOps.reversedPath(s, SliderPath.of(s));
      expect(r.curveType, CurveType.perfectCircle);
      expect(r.position, SliderPath.of(s).tail.roundToInt());
      _expectReversedShape(s, r);
    });

    test('untrimmed sliders just reverse their points; edge sounds reverse', () {
      final s = _slider(CurveType.catmull, const [Vec2(0, 0), Vec2(50, 50), Vec2(100, 0)], 0)
          .copyWith(edgeSounds: const [2, 8], edgeSets: const [EdgeSet(1, 0), EdgeSet(0, 2)]);
      final full = SliderPath.of(s).distance;
      final t = s.copyWith(length: full);
      final r = PatternOps.reversedPath(t, SliderPath.of(t));
      expect(r.allPoints, const [Vec2(100, 0), Vec2(50, 50), Vec2(0, 0)]);
      expect(r.edgeSounds, [8, 2]);
      expect(r.edgeSets, const [EdgeSet(0, 2), EdgeSet(1, 0)]);
    });
  });

  group('reverse in time', () {
    double end(HitObject h) => switch (h) {
          SliderObject() => h.time + 400 * h.slides,
          _ => h.endTimeIfKnown,
        };

    test('mirrors spans in the selection range and keeps new combos in place', () {
      final a = const HitCircle(position: Vec2(0, 0), time: 0, newCombo: true, comboSkip: 1);
      final s = _slider(CurveType.linear, const [Vec2(100, 0), Vec2(200, 0)], 100, time: 100);
      final b = const HitCircle(position: Vec2(300, 0), time: 600);
      final sp = const Spinner(position: Spinner.center, time: 700, endTime: 1000);
      final (before, after) = PatternOps.reversed([b, a, sp, s], endTime: end, pathOf: SliderPath.of);
      expect(before, hasLength(4));
      final byOld = {for (var i = 0; i < before.length; i++) before[i]: after[i]};
      expect(byOld[sp]!.time, 0);
      expect((byOld[sp]! as Spinner).endTime, 300);
      expect(byOld[b]!.time, 400);
      expect(byOld[s]!.time, 500); // 1000 − (500 − 0)
      expect(byOld[s]!.position, const Vec2(200, 0));
      expect(byOld[a]!.time, 1000);
      // The new first object (the spinner) starts the combo, with a's skip.
      expect(byOld[sp]!.newCombo, isTrue);
      expect(byOld[sp]!.comboSkip, 1);
      expect(byOld[a]!.newCombo, isFalse);
    });

    test('a single slider only runs backwards; a single circle is unchanged', () {
      final s = _slider(CurveType.linear, const [Vec2(100, 0), Vec2(200, 0)], 100, time: 100);
      final (before, after) = PatternOps.reversed([s], endTime: end, pathOf: SliderPath.of);
      expect(after.single.time, 100);
      expect(after.single.position, const Vec2(200, 0));
      expect(before.single, same(s));
      final c = const HitCircle(position: Vec2(0, 0), time: 0);
      expect(PatternOps.reversed([c], endTime: end, pathOf: SliderPath.of).$1, isEmpty);
    });

    test('a palindrome-placed middle circle keeps its instance', () {
      final a = const HitCircle(position: Vec2(0, 0), time: 0);
      final m = const HitCircle(position: Vec2(1, 0), time: 50);
      final b = const HitCircle(position: Vec2(2, 0), time: 100);
      final (before, _) = PatternOps.reversed([a, m, b], endTime: end, pathOf: SliderPath.of);
      expect(before, unorderedEquals([a, b]));
    });
  });
}
