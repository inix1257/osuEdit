// Desktop background check: the top timeline shows objects faded (not
// editable) in every editor mode except Compose.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/mode_timeline_test.dart -d windows
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/editor/widgets/editor_mode_button.dart';
import 'package:osu_edit/editor/widgets/timeline_view.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('timeline objects are faded outside Compose', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');

    bool faded() => tester.widget<TimelineView>(find.byType(TimelineView)).objectsInBackground;
    for (final m in [...EditorMode.values.skip(1), EditorMode.compose]) {
      await tester.tap(find.byType(EditorModeButton));
      await settle(tester, const Duration(milliseconds: 400));
      await tester.tap(find.text(m.label).last);
      await settle(tester, const Duration(milliseconds: 600));
      expect(faded(), m != EditorMode.compose, reason: m.label);
      await shot(tester, 'mode_timeline_${m.name}');
    }
  });
}
