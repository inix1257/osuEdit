// Desktop background check: a selected slider's orange outline is only the
// border band, both while the slider fades in and while it is fully visible.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/slider_selection_border_test.dart -d windows
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('selected slider shows only the border outline', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Shapes');
    final EditorController c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    final s = c.beatmap.hitObjects.whereType<SliderObject>().first;
    c.select(s);
    for (final dt in [-600, -200, 100]) {
      c.seek(s.time + dt.toDouble());
      await settle(tester, const Duration(milliseconds: 300));
      await shot(tester, 'slider_sel_border_$dt');
    }
  });
}
