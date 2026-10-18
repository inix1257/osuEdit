// Spinner tool icon: only the outer chasing arrows (no inner swirl / dot).
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/spinner_icon_test.dart -d windows
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('spinner tool icon', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    await settle(tester);
    await shot(tester, 'spinner_icon');
  });
}
