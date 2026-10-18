import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// Sliders may leave the playfield as long as their circle stays on screen
/// (lazer's `CheckOffscreenObjects` box); circles keep the playfield.
EditorController _controller({double cs = 4}) {
  final b = Beatmap.empty();
  b.setValue(SectionNames.difficulty, 'SliderMultiplier', '1.4');
  b.setValue(SectionNames.difficulty, 'CircleSize', '$cs');
  b.insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
  b.revision = 0;
  return EditorController(beatmap: b, document: const BeatmapDocument(fileName: 'new.osu'));
}

void main() {
  test('slider bounds follow the screen minus the circle radius, never inside the playfield', () {
    // CS 4: r = 36.48 → screen (-67, -60, 579, 428) inset, rounded inwards.
    expect(OsuRules.sliderBounds(4), (left: -30.0, top: -23.0, right: 542.0, bottom: 391.0));
    // Smaller circles may go further.
    expect(OsuRules.sliderBounds(7), (left: -43.0, top: -36.0, right: 555.0, bottom: 404.0));
    // CS 0 (r = 54.4) would be inside the playfield at the bottom: kept at 384.
    expect(OsuRules.sliderBounds(0), (left: -12.0, top: -5.0, right: 524.0, bottom: 384.0));
  });

  test('slider head and points may be drawn past the playfield, circles may not', () {
    final c = _controller();
    addTearDown(c.dispose);
    c.seek(1000);
    c.tool = EditorTool.slider;
    c.sliderToolTap(const Vec2(-100, -100)); // head: clamped to the screen box
    c.sliderToolTap(const Vec2(700, 500)); // tail too
    expect(c.draftPoints.map((p) => p.position), [const Vec2(-30, -23), const Vec2(542, 391)]);
    c.finishSlider();
    final s = c.selection.single as SliderObject;
    expect(s.position, const Vec2(-30, -23));

    c.seek(3000);
    c.tool = EditorTool.circle;
    c.placeCircle(const Vec2(-100, -100));
    expect(c.selection.single.position, Vec2.zero);
  });

  test('dragging a slider head and moving a slider stop at the screen box', () {
    final c = _controller();
    addTearDown(c.dispose);
    c.seek(1000);
    c.tool = EditorTool.slider;
    c.sliderToolTap(const Vec2(100, 100));
    c.sliderToolTap(const Vec2(300, 100));
    c.finishSlider();
    c.tool = EditorTool.select;

    c.beginPointDrag(0);
    c.updatePointDrag(const Vec2(-200, 100));
    c.endPointDrag();
    expect((c.selection.single as SliderObject).position, const Vec2(-30, 100));

    c.beginMoveSelection();
    c.updateMoveSelection(const Vec2(-50, -500));
    c.endMoveSelection();
    expect(c.selection.single.position, const Vec2(-30, -23));

  });

  test('with a circle in the moved selection, its playfield bound wins', () {
    final c = _controller();
    addTearDown(c.dispose);
    c.seek(1000);
    c.tool = EditorTool.slider;
    c.sliderToolTap(const Vec2(100, 100));
    c.sliderToolTap(const Vec2(300, 100));
    c.finishSlider();
    final slider = c.selection.single;
    c.seek(5000);
    c.tool = EditorTool.circle;
    c.placeCircle(const Vec2(50, 50));
    c.tool = EditorTool.select;
    c.select(slider, additive: true);
    c.beginMoveSelection();
    c.updateMoveSelection(const Vec2(-500, 0));
    c.endMoveSelection();
    expect({for (final h in c.selection) h.runtimeType: h.position.x}, {HitCircle: 0.0, SliderObject: 50.0});
  });

  test('nudge lets a slider head past the playfield edge up to the screen box', () {
    final c = _controller();
    addTearDown(c.dispose);
    c.seek(1000);
    c.tool = EditorTool.slider;
    c.sliderToolTap(const Vec2(540, 200));
    c.sliderToolTap(const Vec2(400, 200));
    c.finishSlider();
    c.tool = EditorTool.select;
    c.nudgeSelection(2, 0);
    expect(c.selection.single.position, const Vec2(542, 200));
    final edge = c.selection.single;
    c.nudgeSelection(1, 0); // past the box: refused
    expect(identical(c.selection.single, edge), isTrue);
  });
}
