// Compose: star rating chip + combined difficulty graph on both timelines (no
// waveform there; Timing keeps it), Merge button, Resnap / Move menu items.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/compose_tools_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/widgets/editor_mode_button.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('star rating, difficulty graph, merge', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    c.showMiniTimeline = true;
    await waitFor(tester, find.byKey(const ValueKey('star rating')));
    c.seek(c.beatmap.hitObjects[40].time);
    await settle(tester);
    expect(find.textContaining('★ ${c.difficulty.value!.stars.toStringAsFixed(2)}'), findsOneWidget);
    await shot(tester, 'compose_graph');

    // Merge two circles next to each other.
    final circles = c.beatmap.hitObjects.whereType<HitCircle>().toList();
    c.select(circles[10]);
    c.select(circles[11], additive: true);
    await settle(tester);
    expect(find.text('Merge'), findsOneWidget);
    await shot(tester, 'compose_merge_button');
    final before = c.difficulty.value!.stars;
    await tester.tap(find.text('Merge'));
    await settle(tester);
    expect(c.selection.single, isA<SliderObject>());
    await settle(tester, const Duration(seconds: 2)); // re-rated after the edit
    expect(c.difficulty.value!.stars, isNot(before));
    await shot(tester, 'compose_merged');

    // The Edit menu has the resnap / move items.
    await tester.tap(find.byTooltip('Menu'));
    await settle(tester);
    await tester.tap(find.text('Edit'));
    await settle(tester);
    expect(find.textContaining('Resnap selection'), findsOneWidget);
    expect(find.text('Move selection in time…'), findsOneWidget);
    await shot(tester, 'compose_edit_menu');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    // Timing keeps the waveform, without the graph.
    await tester.tap(find.byType(EditorModeButton));
    await settle(tester);
    await tester.tap(find.text('Timing').last);
    await settle(tester, const Duration(seconds: 1));
    await shot(tester, 'timing_waveform');
  });
}
