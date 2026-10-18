// Spinner fades in (lazer: TimeFadeIn ending at its start) instead of popping in.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/spinner_fade_test.dart -d windows
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_screen.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('spinner fade-in', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    final spinner = c.beatmap.hitObjects.whereType<Spinner>().first;
    final fade = c.fadeIn;
    for (final (dt, name) in [(-fade * 0.75, 'a'), (-fade * 0.5, 'b'), (-fade * 0.25, 'c'), (0.0, 'd')]) {
      c.seek(spinner.time + dt);
      await settle(tester, const Duration(milliseconds: 200));
      await shot(tester, 'spinner_fade_$name');
    }
  });
}
