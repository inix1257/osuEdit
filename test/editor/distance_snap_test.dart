import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/widgets/editor_toolbars.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// Distance snap rules (compared with lazer): stable first —
/// the playhead fixes the time, the slider velocity is the one at that time,
/// grid snap wins — and lazer where stable is unknown (no ring after a
/// spinner, stacked anchor, a running slider still anchors, no ring point
/// off the playfield).
///
/// 120 BPM from 0, SliderMultiplier 1.4: 0.28 px/ms at SV 1.
EditorController _make(List<HitObject> objs, {List<TimingPoint> greens = const []}) {
  final b = Beatmap.empty()..insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
  for (final g in greens) {
    b.insertTimingPoint(g);
  }
  for (final h in objs) {
    b.insertHitObject(h);
  }
  b.revision = 0;
  final c = EditorController(beatmap: b, document: const BeatmapDocument(fileName: 'x.osu'));
  c.distanceSnap = true;
  return c;
}

void main() {
  test('no ring after a spinner: placement is free (it used to land on the playfield edge)', () {
    final c = _make([
      const HitCircle(position: Vec2(100, 192), time: 0),
      const Spinner(position: Vec2(256, 192), time: 500, endTime: 3000),
    ]);
    addTearDown(c.dispose);
    expect(c.distanceSnapGuide(3500), isNull);
    expect(c.placementPosition(const Vec2(300, 200), 3500), const Vec2(300, 200));
    // Grid snap still applies.
    c.gridSnap = true;
    expect(c.placementPosition(const Vec2(300, 200), 3500), const Vec2(288, 192));
  });

  test('the slider velocity is the one at the placement time (stable: current timing point)', () {
    final c = _make([const HitCircle(position: Vec2(100, 192), time: 1000)], greens: [
      TimingPoint.green(time: 1000, sliderVelocity: 2),
      TimingPoint.green(time: 1400, sliderVelocity: 1),
    ]);
    addTearDown(c.dispose);
    expect(c.distanceSnapGuide(1500)!.$2, closeTo(0.28 * 500, 1e-6), reason: 'SV 1 at 1500, not SV 2 at the circle');
    expect(c.distanceSnapGuide(1300)!.$2, closeTo(0.28 * 2 * 300, 1e-6));
  });

  test('grid snap wins over distance snap', () {
    final c = _make([const HitCircle(position: Vec2(100, 192), time: 0)]);
    addTearDown(c.dispose);
    final ring = c.placementPosition(const Vec2(203, 250), 500);
    expect(ring.distanceTo(const Vec2(100, 192)), closeTo(140, 1));
    c.gridSnap = true;
    final p = c.placementPosition(const Vec2(203, 250), 500);
    expect(p.x % c.gridSize, 0);
    expect(p.y % c.gridSize, 0);
    // The grid point nearest the ring point (lazer snaps the distance result).
    expect(p, c.snapPosition(ring));
  });

  test('a ring point off the playfield gives up distance snap', () {
    final c = _make([const HitCircle(position: Vec2(500, 192), time: 0)]);
    addTearDown(c.dispose);
    // Radius 140 to the right would be x = 640.
    expect(c.placementPosition(const Vec2(510, 192), 500), const Vec2(510, 192));
    // Towards the inside it still snaps.
    expect(c.placementPosition(const Vec2(400, 192), 500), const Vec2(360, 192));
  });

  test('the ring is around the previous object as drawn (stack offset)', () {
    final c = _make([
      const HitCircle(position: Vec2(200, 192), time: 0),
      const HitCircle(position: Vec2(200, 192), time: 250),
    ]);
    addTearDown(c.dispose);
    c.showStacking = true;
    final first = c.beatmap.hitObjects.first;
    final off = c.stackOffsetOf(first);
    expect(off, isNot(Vec2.zero));
    expect(c.distanceSnapGuide(125)!.$1, const Vec2(200, 192) + off);
    c.showStacking = false;
    expect(c.distanceSnapGuide(125)!.$1, const Vec2(200, 192));
  });

  test('inside a running slider the slider still anchors (lazer), the gap the other way', () {
    final c = _make([
      const HitCircle(position: Vec2(100, 100), time: 0),
      const SliderObject(
          position: Vec2(300, 192), time: 500, curveType: CurveType.linear, controlPoints: [Vec2(450, 192)], length: 150),
    ]);
    addTearDown(c.dispose);
    final s = c.beatmap.hitObjects.last as SliderObject;
    final end = c.endTimeOf(s);
    final (centre, r) = c.distanceSnapGuide(750)!;
    expect(centre, const Vec2(450, 192));
    expect(r, closeTo(0.28 * (end - 750), 1e-6));
  });

  test('moving: the earliest object stays on the ring, then the grid wins', () {
    final c = _make(const []);
    addTearDown(c.dispose);
    c.distanceSnap = false;
    c.placeCircle(const Vec2(100, 100)); // at 0
    c.seek(500);
    c.placeCircle(const Vec2(300, 100));
    c.distanceSnap = true;
    c.gridSnap = true;
    c.beginMoveSelection();
    c.updateMoveSelection(const Vec2(0, 50));
    c.endMoveSelection();
    final p = c.selection.single.position;
    expect(p.x % c.gridSize, 0);
    expect(p.y % c.gridSize, 0);
  });

  test('distance spacing: 0.01 steps, shown with one or two decimals', () {
    final c = _make(const []);
    addTearDown(c.dispose);
    c.setDistanceSpacing(1.256);
    expect(c.distanceSpacing, 1.26);
    expect(formatSpacing(1.26), '1.26');
    expect(formatSpacing(1.2), '1.2');
    expect(formatSpacing(1), '1.0');
  });
}
