// Library star ratings: the list appears first, ratings are computed in the
// background and then shown on each difficulty (sorted by rating).
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/star_rating_test.dart -d windows
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/home/song_select.dart';
import 'package:osu_edit/platform/beatmap_library.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('difficulties show their star rating', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openSet(tester, 'Sync Test');
    await waitFor(tester, find.textContaining('★'));
    await settle(tester);
    await shot(tester, 'star_rating_home');

    // The shown values are the calculator's, in ascending order.
    final set = (await tester.runAsync(lib.listSets))!.single;
    final expected = <double>[];
    for (final d in set.difficulties) {
      final text = File(d.path).readAsStringSync();
      expected.add(StarRating.of(OsuParser.parse(text))!);
      expect(d.starRating, closeTo(expected.last, 1e-9));
      expect(find.descendant(of: find.byType(DifficultyCard), matching: find.text('★ ${expected.last.toStringAsFixed(2)}')),
          findsOneWidget);
    }
    expect(expected, [...expected]..sort());
    expect(File(BeatmapLibrary.joinPath(lib.root.path, '.star_ratings.json')).existsSync(), isTrue);
  });
}
