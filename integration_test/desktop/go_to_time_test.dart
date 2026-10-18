// Desktop background check: tapping the bottom-left time opens the
// minute / second / millisecond wheels; "Manual input" opens the timestamp
// text prompt.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/go_to_time_test.dart -d windows
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/editor/editor_screen.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('go to time wheels and manual input', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;

    await tester.tap(find.byTooltip('Go to time'));
    await settle(tester, const Duration(milliseconds: 400));
    expect(find.byType(CupertinoPicker), findsNWidgets(3));
    await shot(tester, 'go_to_time_wheels');

    // Scroll: minutes stay 0, seconds +2, milliseconds +5.
    final pickers = find.byType(CupertinoPicker);
    await tester.drag(pickers.at(1), const Offset(0, -64));
    await settle(tester, const Duration(milliseconds: 600));
    await tester.drag(pickers.at(2), const Offset(0, -160));
    await settle(tester, const Duration(milliseconds: 600));
    await shot(tester, 'go_to_time_scrolled');
    await tester.tap(find.text('Go'));
    await settle(tester, const Duration(milliseconds: 400));
    expect(c.time.value, 3005); // started at 00:01:000
    await shot(tester, 'go_to_time_after');

    await tester.tap(find.byTooltip('Go to time'));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('Manual input'));
    await settle(tester, const Duration(milliseconds: 400));
    expect(find.text('Go to timestamp'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '00:04:500 -');
    await settle(tester, const Duration(milliseconds: 200));
    await shot(tester, 'go_to_time_manual');
    await tester.tap(find.text('Go'));
    await settle(tester, const Duration(milliseconds: 400));
    expect(c.time.value, 4500);
  });
}
