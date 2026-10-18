// Play/pause button in the bottom-right bar has its own fill + outline.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/play_button_style_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('play button is visually distinct', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final btn = find.widgetWithIcon(IconButton, Icons.play_arrow);
    expect(btn, findsOneWidget);
    expect(tester.widget<IconButton>(btn).style?.side, isNotNull);
    await shot(tester, 'play_button_style');
  });
}
