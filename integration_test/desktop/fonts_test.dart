// Desktop background check of the bundled fonts (Exo 2 UI, JetBrains Mono
// numbers): the theme font is Exo 2, the editor time readout is JetBrains Mono,
// and screenshots show both in the library and the editor.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/fonts_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/app_fonts.dart';
import 'package:osu_edit/editor/editor_screen.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('UI is Exo 2, timestamps are JetBrains Mono', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    expect(Theme.of(tester.element(find.byType(Scaffold).first)).textTheme.bodyMedium?.fontFamily, kUiFont);
    await shot(tester, 'fonts_home');

    await openDifficulty(tester, 'Sync Test', 'Snaps');
    expect(find.byType(EditorScreen), findsOneWidget);
    final time = tester.widget<Text>(find.textContaining(RegExp(r'^-?\d\d:\d\d:\d\d\d$')).first);
    expect(time.style?.fontFamily, kMonoFont);
    await shot(tester, 'fonts_editor');
  });
}
