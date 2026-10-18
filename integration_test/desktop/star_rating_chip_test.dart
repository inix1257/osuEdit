// Desktop background check: Compose's star rating at the top left of the
// inner area (just right of Sample / Addition), fading in a second after the
// selection is cleared and hidden while the side strips show.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/star_rating_chip_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/editor/editor_screen.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('star rating chip', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    final chip = find.byKey(const ValueKey('star rating'));
    await waitFor(tester, chip);
    double opacity() =>
        tester.widget<AnimatedOpacity>(find.ancestor(of: chip, matching: find.byType(AnimatedOpacity))).opacity;

    await settle(tester, const Duration(milliseconds: 1500));
    expect(opacity(), 1);
    await shot(tester, 'sr_chip_shown');

    c.select(c.beatmap.hitObjects[3]);
    await tester.pump();
    expect(opacity(), 0);
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'sr_chip_hidden_selected');

    c.clearSelection();
    await settle(tester, const Duration(milliseconds: 500));
    expect(opacity(), 0, reason: 'not before a second');
    await settle(tester, const Duration(milliseconds: 650));
    await shot(tester, 'sr_chip_fading');
    await settle(tester, const Duration(milliseconds: 400));
    expect(opacity(), 1);
  });
}
