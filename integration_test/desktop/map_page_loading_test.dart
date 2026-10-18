// Song select: the info panel's "Map page" button (osu! website page of the
// selected difficulty; disabled for unsubmitted maps) and the dim + loading
// card shown while a difficulty opens.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/map_page_loading_test.dart -d windows
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/home/song_select.dart';
import 'package:osu_edit/platform/web_links.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('map page button and loading dim', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    // Make [Snaps] a "submitted" map; [Shapes] stays unsubmitted.
    final set = (await tester.runAsync(lib.listSets))!.single;
    final snaps = set.difficulties.firstWhere((d) => d.summary.version == 'Snaps');
    await tester.runAsync(() async {
      final f = File(snaps.path);
      final text = (await f.readAsString())
          .replaceFirst(RegExp(r'BeatmapID:.*'), 'BeatmapID:123456')
          .replaceFirst(RegExp(r'BeatmapSetID:.*'), 'BeatmapSetID:654321');
      await f.writeAsString(text);
    });
    final opened = <String>[];
    WebLinks.debugOpen = (url) async {
      opened.add(url);
      return true;
    };
    addTearDown(() => WebLinks.debugOpen = null);

    await pumpApp(tester, lib);
    await openSet(tester, 'Sync Test');
    final button = find.byType(MapPageButton);
    expect(button, findsOneWidget);

    // Shapes (selected first): no page.
    final shapesCard = find.ancestor(of: find.text('Shapes'), matching: find.byType(DifficultyCard)).first;
    if (!tester.widget<DifficultyCard>(shapesCard).selected) {
      await tester.tap(shapesCard);
      await settle(tester, const Duration(milliseconds: 300));
    }
    expect(tester.widget<MapPageButton>(button).onPressed, isNull);
    await shot(tester, 'map_page_disabled');

    // Snaps: its page, with the difficulty.
    final snapsCard = find.ancestor(of: find.text('Snaps'), matching: find.byType(DifficultyCard)).first;
    await tester.tap(snapsCard);
    await settle(tester, const Duration(milliseconds: 300));
    expect(tester.widget<MapPageButton>(button).onPressed, isNotNull);
    await shot(tester, 'map_page_enabled');
    await tester.tap(button);
    await settle(tester, const Duration(milliseconds: 200));
    expect(opened, ['https://osu.ppy.sh/beatmapsets/654321#osu/123456']);

    // Opening it: the screen dims with a loading card until the editor is in.
    await tester.tap(snapsCard);
    final end = DateTime.now().add(const Duration(seconds: 10));
    final loading = find.text('Loading…');
    while (loading.evaluate().isEmpty && DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(loading, findsOneWidget);
    expect(find.text('[Snaps]'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200)); // faded in
    await shot(tester, 'map_loading_overlay');
    await waitFor(tester, find.byType(EditorScreen));
    await settle(tester, const Duration(seconds: 1));
    expect(tester.widget<LoadingOverlay>(find.byType(LoadingOverlay, skipOffstage: false)).opening, isNull);

    // Back on song select: no dim left.
    await back(tester);
    await settle(tester, const Duration(seconds: 1));
    expect(find.byType(EditorScreen), findsNothing);
    expect(tester.widget<LoadingOverlay>(find.byType(LoadingOverlay, skipOffstage: false)).opening, isNull);
    await shot(tester, 'map_loading_back');
  });
}
