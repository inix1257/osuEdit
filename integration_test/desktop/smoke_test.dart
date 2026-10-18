// Desktop background smoke test: imports the test set into a temp library,
// opens [Snaps] and [Shapes] in the real editor (real file IO, real SoLoud)
// and saves screenshots. Template for background feature checks.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/smoke_test.dart -d windows
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/editor/editor_screen.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('library → editor opens test maps', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await shot(tester, 'smoke_home');

    await openDifficulty(tester, 'Sync Test', 'Snaps');
    expect(find.byType(EditorScreen), findsOneWidget);
    await shot(tester, 'smoke_editor_snaps');

    // Back to the library and into the other difficulty.
    await back(tester);
    await waitFor(tester, find.text('Shapes'));
    await tapDifficulty(tester, 'Shapes');
    await waitFor(tester, find.byType(EditorScreen));
    await settle(tester, const Duration(seconds: 1));
    await shot(tester, 'smoke_editor_shapes');
  });
}
