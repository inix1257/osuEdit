// Song select (home screen, osu!stable style): background, info panel, set
// cards with difficulty dots, open set → difficulty cards with SR, scrolling,
// and the preview song (real SoLoud at volume 0: silent).
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/song_select_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/home/song_select.dart';
import 'package:osu_edit/platform/preview_audio.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('song select cards, SR, scrolling and preview', (tester) async {
    final lib = await tempLibrary(osz: [
      'tool/test_set/osuEdit test set.osz',
      'tool/test_set/osuEdit lazer test.osz',
      'tool/test_set/osuEdit storyboard test.osz',
      'tool/test_set/osuEdit long test.osz',
      'tool/test_set/osuEdit test set.osz',
      'tool/test_set/osuEdit test set.osz',
      'tool/test_set/osuEdit test set.osz',
    ]);
    final preview = SoloudPreviewPlayer(volume: 0);
    await pumpApp(tester, lib, preview: preview);
    await waitFor(tester, find.byType(SetCard));
    // Star ratings are computed in the background on first listing.
    await settle(tester, const Duration(seconds: 3));
    await shot(tester, 'song_select_home');
    expect(preview.isPlaying, isFalse);

    // Open the test set: its difficulties slide in with their SR.
    await openSet(tester, 'Sync Test');
    await settle(tester, const Duration(seconds: 1));
    expect(find.byType(DifficultyCard), findsNWidgets(2));
    expect(find.descendant(of: find.byType(DifficultyCard), matching: find.textContaining('★ ')), findsNWidgets(2));
    await shot(tester, 'song_select_open');
    // The preview plays from the first (easiest) difficulty's PreviewTime
    // ([Shapes]: 1 s).
    final sets = (await tester.runAsync(lib.listSets))!;
    final from = sets.firstWhere((s) => s.title == 'Sync Test').previewSource!.summary.previewTime / 1000;
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (!preview.isPlaying && DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(preview.isPlaying, isTrue);
    expect(preview.position, inInclusiveRange(from - 0.1, from + 3));

    // Selecting another difficulty shows its stats; the same song goes on.
    final snaps = find.ancestor(of: find.text('Snaps'), matching: find.byType(DifficultyCard)).first;
    await tester.tap(snaps);
    await settle(tester);
    expect(find.byType(EditorScreen), findsNothing);
    expect(tester.widget<DifficultyCard>(snaps).selected, isTrue);
    expect(find.descendant(of: find.byType(MapInfoPanel), matching: find.text('Snaps')), findsOneWidget);
    expect(preview.isPlaying, isTrue);
    await shot(tester, 'song_select_diff_selected');

    // Scroll the carousel.
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await settle(tester);
    await shot(tester, 'song_select_scrolled');
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await settle(tester);

    // Closing the set stops the preview.
    await tester.tap(setCard('Sync Test').first);
    await settle(tester, const Duration(milliseconds: 800));
    expect(find.byType(DifficultyCard), findsNothing);
    expect(preview.isPlaying, isFalse);

    // Another set previews; opening a difficulty stops it for the editor.
    await openSet(tester, 'Lazer Test');
    final end2 = DateTime.now().add(const Duration(seconds: 5));
    while (!preview.isPlaying && DateTime.now().isBefore(end2)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(preview.isPlaying, isTrue);
    await shot(tester, 'song_select_lazer');
    await tapDifficulty(tester, 'Lazer');
    await waitFor(tester, find.text('osu!lazer slider format'));
    await tester.tap(find.text('Keep lazer format'));
    await waitFor(tester, find.byType(EditorScreen));
    await settle(tester, const Duration(seconds: 1));
    expect(preview.isPlaying, isFalse);

    // Back on song select: the open set plays again.
    await back(tester);
    final end3 = DateTime.now().add(const Duration(seconds: 5));
    while (!preview.isPlaying && DateTime.now().isBefore(end3)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(preview.isPlaying, isTrue);
    await preview.stop();
  });

  testWidgets('empty library', (tester) async {
    final lib = await tempLibrary();
    await pumpApp(tester, lib);
    await waitFor(tester, find.textContaining('No beatmaps yet'));
    await shot(tester, 'song_select_empty');
  });
}
