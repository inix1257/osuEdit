// Desktop background check: a selection box dragged while time moves
// (playback, simulated by stepping the clock so nothing plays out loud)
// keeps the objects it caught after they disappear.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/box_select_playback_test.dart -d windows
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/playfield_transform.dart';
import 'package:osu_edit/editor/widgets/playfield_view.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('box select during playback keeps earlier objects', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Shapes');
    final EditorController c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    final objs = c.beatmap.hitObjects.where((h) => h is! Spinner).toList();
    final start = objs.first.time.toDouble();
    c.seek(start);
    await settle(tester, const Duration(milliseconds: 300));

    final area = tester.getRect(find.byType(PlayfieldView));
    final tf = PlayfieldTransform.fit(area.size, c.playfieldZoom.value);
    Offset at(double x, double y) => area.topLeft + tf.toScreen(Vec2(x, y));
    final g = await tester.startGesture(at(-20, -15));
    await g.moveTo(at(260, 200));
    await g.moveTo(at(530, 400));
    await tester.pump();
    final first = c.selection.toSet();
    expect(first, isNotEmpty);

    // Keep holding (with a little wiggle) while the map plays on for 4 s.
    for (var t = 0; t < 4000; t += 50) {
      c.seek(start + t);
      if (t % 500 == 0) await g.moveBy(Offset(t % 1000 == 0 ? 2 : -2, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await shot(tester, 'box_select_playback_dragging');
    await g.up();
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'box_select_playback_after');

    final shown = c.visibleObjectsAt(c.time.value).toSet();
    expect(first.difference(shown), isNotEmpty, reason: 'some caught objects are gone by now');
    expect(c.selection, containsAll(first));
    expect(c.selection.length, greaterThan(first.length));
    expect(c.canUndo, isFalse);
  });
}
