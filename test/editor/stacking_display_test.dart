import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// Stacking is display-only: objects are drawn and hit-tested shifted, but
/// edits keep working on the file positions.
void main() {
  // 120 BPM from 0. A slider at (100,100)→(200,100) @0, then a circle on its
  // head @500 (stacks the slider) and two circles on one spot @1000/@1250.
  EditorController make() {
    final b = Beatmap.empty();
    b.insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
    b.insertHitObject(const SliderObject(
      position: Vec2(100, 100),
      time: 0,
      curveType: CurveType.linear,
      controlPoints: [Vec2(200, 100)],
      length: 100,
    ));
    b.insertHitObject(const HitCircle(position: Vec2(100, 100), time: 500));
    b.insertHitObject(const HitCircle(position: Vec2(300, 300), time: 1000));
    b.insertHitObject(const HitCircle(position: Vec2(300, 300), time: 1250));
    b.revision = 0;
    return EditorController(beatmap: b, document: const BeatmapDocument(fileName: 'new.osu'));
  }

  test('stack heights and display positions', () {
    final c = make();
    final objs = c.beatmap.hitObjects;
    final d = c.circleRadius / 10;
    expect([for (final h in objs) c.stackHeightOf(h)], [1, 0, 1, 0]);
    expect(c.displayPositionOf(objs[2]), Vec2(300 - d, 300 - d));
    expect(c.displayPositionOf(objs[3]), const Vec2(300, 300));
    expect(objs[2].position, const Vec2(300, 300)); // the file is untouched
  });

  test('hit testing uses the stacked position', () {
    final c = make();
    final objs = c.beatmap.hitObjects;
    final r = c.circleRadius;
    final shown = c.displayPositionOf(objs[2]);
    // Just inside the stacked circle's left edge, outside the unstacked one.
    final p = Vec2(shown.x - r + 0.5, shown.y);
    expect(identical(c.hitTest(p, 1250), objs[2]), isTrue);
    expect(c.hitTest(Vec2(300 + r - 0.5, 300), 1000), same(objs[3]));
  });

  test('control points of a stacked slider are grabbed and dragged where they are shown', () {
    final c = make();
    final s = c.beatmap.hitObjects[0] as SliderObject;
    c.select(s);
    final off = c.stackOffsetOf(s);
    expect(off, isNot(Vec2.zero));
    expect(c.hitTestControlPoint(const Vec2(200, 100) + off, 1), 1);
    expect(c.hitTestControlPoint(const Vec2(200, 100) + off * 3, 1), isNull);

    c.beginPointDrag(1);
    c.updatePointDrag(const Vec2(200, 150) + off);
    c.endPointDrag();
    final moved = c.beatmap.hitObjects.whereType<SliderObject>().single;
    expect(moved.controlPoints.last, const Vec2(200, 150));
  });

  test('box select uses the stacked head position', () {
    final c = make();
    c.time.value = 1000;
    final objs = c.beatmap.hitObjects;
    final shown = c.displayPositionOf(objs[2]);
    // A box around the stacked head only.
    c.beginBoxSelect(shown - const Vec2(1, 1));
    c.updateBoxSelect(shown + const Vec2(1, 1));
    c.endBoxSelect();
    expect(c.selection.toList(), [same(objs[2])]);
  });
}
