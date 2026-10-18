// Bottom bar: time, overview toggle, play button and rate dropdown are all
// vertically centred in the strip (expanded and collapsed).
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/bottom_bar_center_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/editor/editor_screen.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('bottom bar items are vertically centred', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final screenH = tester.getSize(find.byType(EditorScreen)).height;

    Future<void> check(String name) async {
      final play = find.widgetWithIcon(IconButton, Icons.play_arrow);
      final playRect = tester.getRect(play);
      // The strip spans from the play button's top to the screen bottom.
      final stripCentre = (playRect.top + screenH) / 2;
      final items = {
        'play icon': find.descendant(of: play, matching: find.byIcon(Icons.play_arrow)),
        'play button': play,
        'time': find.textContaining(RegExp(r'^\d\d:\d\d:\d\d\d$')),
        'toggle': find.byWidgetPredicate((w) =>
            w is Icon && (w.icon == Icons.expand_more || w.icon == Icons.expand_less)),
        'rate': find.text('100%').last,
      };
      for (final e in items.entries) {
        final r = tester.getRect(e.value.first);
        // ignore: avoid_print
        print('$name ${e.key}: centre ${r.center.dy.toStringAsFixed(1)} vs strip ${stripCentre.toStringAsFixed(1)}');
        expect((r.center.dy - stripCentre).abs(), lessThan(1.0), reason: '$name ${e.key}');
      }
      // The play glyph gets its full square (a squeezed box draws it low).
      final icon = tester.getSize(items['play icon']!);
      expect(icon.height, icon.width);
      await shot(tester, 'bottom_bar_$name');
    }

    // Both states of the overview toggle (whichever is the default).
    await check('a');
    await tester.tap(find.byWidgetPredicate((w) =>
        w is Icon && (w.icon == Icons.expand_more || w.icon == Icons.expand_less)));
    await settle(tester);
    await check('b');
  });
}
