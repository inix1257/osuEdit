// Desktop background check: the Timing mode's BPM view (detailed waveform
// strip + beat rows) on the test set's click track, with the right BPM and
// a slightly wrong one (attacks drift across the rows).
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/bpm_view_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/widgets/editor_mode_button.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('BPM view: detailed waveform and beat rows', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final EditorController c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    await c.waveformLoaded;

    await tester.tap(find.byType(EditorModeButton));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text(EditorMode.timing.label).last);
    await tester.pump();
    expect(find.byKey(const ValueKey('bpm-rows')), findsOneWidget);
    expect(find.text('Kiai time'), findsNothing);
    expect(find.text('Slider tick rate'), findsNothing);

    final watch = Stopwatch()..start();
    while (c.detailedWaveform == null && watch.elapsed < const Duration(seconds: 60)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // ignore: avoid_print
    print('detailed waveform: ${watch.elapsedMilliseconds} ms, '
        '${c.detailedWaveform?.sampleRate} Hz, ${c.detailedWaveform?.duration.round()} ms');
    expect(c.detailedWaveform, isNotNull);
    expect(c.detailedWaveform!.duration, closeTo(c.clock.duration!, 50));

    final red = c.timing.redPoints.first;
    c.seek(red.time + red.beatLength * 8);
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'bpm_view_beats', pixelRatio: phoneDpr);

    await tester.tap(find.text('Bar'));
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'bpm_view_bars', pixelRatio: phoneDpr);

    // 1 BPM too fast: the attacks walk off the centre line row by row.
    await tester.tap(find.text('Beat'));
    c.retimePoint(red, red.copyWith(beatLength: 60000 / (red.bpm + 1)));
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'bpm_view_wrong_bpm', pixelRatio: phoneDpr);
    c.undo();

    // Rows: dragging up moves on by rows.
    final before = c.time.value;
    final rows = tester.getRect(find.byKey(const ValueKey('bpm-rows')));
    await tester.dragFrom(Offset(rows.center.dx, rows.bottom - 4), const Offset(0, -80));
    await settle(tester, const Duration(milliseconds: 300));
    expect(c.time.value, greaterThan(before));
    await shot(tester, 'bpm_view_scrolled', pixelRatio: phoneDpr);
  });
}
