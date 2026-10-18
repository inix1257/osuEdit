// Song select: long-pressing a difficulty opens a drop-down menu (open .osu,
// map page, song folder, delete); the info panel shows OBJECTS next to
// LENGTH / BPM.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/difficulty_menu_test.dart -d windows
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/home/song_select.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('difficulty long-press menu and objects stat', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openSet(tester, 'Sync Test');
    expect(find.text('OBJECTS'), findsOneWidget);

    final card = find.ancestor(of: find.text('Snaps'), matching: find.byType(DifficultyCard)).first;
    await tester.longPress(card);
    await settle(tester, const Duration(milliseconds: 400));
    expect(find.text('Open .osu file'), findsOneWidget);
    expect(find.text('Open song folder'), findsOneWidget);
    expect(find.text('Delete difficulty'), findsOneWidget);
    await shot(tester, 'difficulty_menu');

    await tester.tap(find.text('Open .osu file'));
    await waitFor(tester, find.byType(EditorScreen));
  });

  testWidgets('refresh button shows the loading card', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Refreshing…'), findsOneWidget);
    await shot(tester, 'refresh_loading');
    await settle(tester, const Duration(milliseconds: 1200));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<LoadingOverlay>(find.byType(LoadingOverlay, skipOffstage: false)).opening, isNull);
  });
}
