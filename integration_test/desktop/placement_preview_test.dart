// Desktop background check: with the Circle tool, holding a finger shows the
// circle to be placed (combo colour / number, the next objects renumbered,
// a ghost on the timeline, red when the time is taken).
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/placement_preview_test.dart -d windows
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/playfield_transform.dart';
import 'package:osu_edit/editor/widgets/playfield_view.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('circle placement preview', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final EditorController c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    c.tool = EditorTool.circle;
    final objs = c.beatmap.hitObjects;
    // Between the 2nd and 3rd objects.
    c.seek(timingMid(objs[1].time, objs[2].time, c));
    await settle(tester, const Duration(milliseconds: 300));
    final rect = tester.getRect(find.byType(PlayfieldView));
    Offset at(Vec2 p) => rect.topLeft + PlayfieldTransform.fit(rect.size, c.playfieldZoom.value).toScreen(p);

    final g = await tester.startGesture(at(const Vec2(400, 300)));
    await settle(tester, const Duration(milliseconds: 300));
    expect(c.placementGhostCombo, isNotNull);
    expect(c.placementCollides, isFalse);
    await shot(tester, 'placement_hold');
    await g.up();
    await settle(tester, const Duration(milliseconds: 300));
    expect(c.beatmap.hitObjects.length, objs.length);
    c.undo();
    await settle(tester, const Duration(milliseconds: 200));

    // On an object's time: red.
    c.seek(objs[2].time);
    await settle(tester, const Duration(milliseconds: 300));
    final g2 = await tester.startGesture(at(const Vec2(400, 300)));
    await settle(tester, const Duration(milliseconds: 300));
    expect(c.placementCollides, isTrue);
    await shot(tester, 'placement_collides');
    await g2.cancel();
    await settle(tester, const Duration(milliseconds: 300));
    expect(c.placementGhost, isNull, reason: 'a cancelled press drops the preview');
  });
}

/// A snapped time between [a] and [b].
double timingMid(double a, double b, EditorController c) => c.timing.snap((a + b) / 2, c.divisor);
