// The dev app (version name x.y.z-dev) shows a small "TEST BUILD" tag on the
// song select and editor screens; the release app does not.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/dev_badge_test.dart -d windows
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/platform/app_updater.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('TEST BUILD tag only in the dev app', (tester) async {
    AppUpdater.debugVersion = '0.1.1-dev';
    addTearDown(() => AppUpdater.debugVersion = null);
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('TEST BUILD'), findsOneWidget);
    await shot(tester, 'dev_badge_select');
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    expect(find.text('TEST BUILD'), findsOneWidget);
    await shot(tester, 'dev_badge_editor');
  });

  testWidgets('no tag in the release app', (tester) async {
    AppUpdater.debugVersion = '0.1.1';
    addTearDown(() => AppUpdater.debugVersion = null);
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('TEST BUILD'), findsNothing);
  });
}
