// The timeline's break pill has a border (red-tinted when the break is invalid).
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/break_pill_border_test.dart -d windows
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_screen.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('break pill border', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    // Only deletable breaks show the pill (a gap that must hold one hides it):
    // one past the last object.
    final end = c.endTimeOf(c.beatmap.hitObjects.last).round();
    c.history.execute(AddBreakCommand(end + 500, end + 4000));
    final g = (c.breaks.last.start, c.breaks.last.end);
    c.timelineZoom = 0.2;
    c.seek((g.$1 + g.$2) / 2);
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'break_pill_border');
  });
}
