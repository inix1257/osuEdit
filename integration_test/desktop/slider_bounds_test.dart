// Desktop background check: slider points may be placed a little past the
// playfield (as far as the circle stays on screen, by CS), circles may not.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/slider_bounds_test.dart -d windows
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/playfield_transform.dart';
import 'package:osu_edit/editor/widgets/playfield_view.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('slider placement past the playfield edge', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final EditorController c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    final b = OsuRules.sliderBounds(c.beatmap.circleSize);
    final objs = c.beatmap.hitObjects;
    c.seek(c.timing.snap(c.endTimeOf(objs.last) + 2000, c.divisor));
    await settle(tester, const Duration(milliseconds: 300));
    final rect = tester.getRect(find.byType(PlayfieldView));
    Offset at(Vec2 p) => rect.topLeft + PlayfieldTransform.fit(rect.size, c.playfieldZoom.value).toScreen(p);

    // A head tapped left of the playfield: kept on screen (b.left < 0).
    c.tool = EditorTool.slider;
    await settle(tester, const Duration(milliseconds: 200));
    await tester.tapAt(at(const Vec2(-80, 150)));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tapAt(at(const Vec2(200, 150)));
    await settle(tester, const Duration(milliseconds: 400));
    expect(c.draftPoints.first.position.x, b.left);
    await shot(tester, 'slider_bounds_draft');
    c.finishSlider();
    await settle(tester, const Duration(milliseconds: 400));
    var s = c.selection.single as SliderObject;
    expect(s.position.x, lessThan(0));
    await shot(tester, 'slider_bounds_placed');

    // Dragging the head far above the view stops at the top of the box.
    c.tool = EditorTool.select;
    await settle(tester, const Duration(milliseconds: 300));
    final g = await tester.startGesture(at(s.position + c.stackOffsetOf(s)));
    for (var y = 150.0; y >= -150; y -= 20) {
      await g.moveTo(at(Vec2(s.position.x, y)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await settle(tester, const Duration(milliseconds: 400));
    s = c.beatmap.hitObjects.whereType<SliderObject>().last;
    expect(s.position, Vec2(b.left, b.top));
    await shot(tester, 'slider_bounds_head_drag');

    // A circle tapped at the same spot stays on the playfield.
    c.seek(c.timing.snap(c.endTimeOf(s) + 1000, c.divisor));
    c.tool = EditorTool.circle;
    await settle(tester, const Duration(milliseconds: 300));
    await tester.tapAt(at(const Vec2(-80, 150)));
    await settle(tester, const Duration(milliseconds: 400));
    expect(c.selection.single.position.x, 0);
    await shot(tester, 'slider_bounds_circle');
  });
}
