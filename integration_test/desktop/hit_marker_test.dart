// lazer editor hit marker ring (HitCircleOverlapMarker): with hit markers on,
// the approach circle hands over to a combo-coloured ring at the hit time
// that grows to 1.1x and fades over 700 ms.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/hit_marker_test.dart -d windows
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_screen.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('hit marker ring after the hit time', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    c.hitAnimations = false;
    final circle = c.beatmap.hitObjects.whereType<HitCircle>().elementAt(20);

    Future<void> at(double t, String name) async {
      c.seek(t);
      await settle(tester, const Duration(milliseconds: 200));
      await shot(tester, name);
    }

    await at(circle.time - 30, 'marker_before');
    await at(circle.time + 40, 'marker_40');
    await at(circle.time + 350, 'marker_350');
    await at(circle.time + 650, 'marker_650');
    c.hitAnimations = true;
    await at(circle.time + 40, 'marker_anim_none');
  });
}
